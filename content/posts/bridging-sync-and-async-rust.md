---
title: "如何在同步的 Rust 方法中调用异步方法？"
date: 2022-10-30T21:42:33+08:00
draft: false
toc: true
images:
tags: 
  - Rust
---

## 背景和问题
最近在做我们的 [GreptimeDB](https://greptime.com/) 项目的时候遇到一个关于在同步 Rust 方法中调用异步代码的问题，排查清楚之后大大加深了对异步 Rust 的理解，因此在这篇文章中记录一下。

我们的整个项目是基于 [Tokio](https://tokio.rs/) 这个异步 Rust runtime 的，它将协作式的任务运行和调度方便地封装在 `.await` 调用中，非常简洁优雅。但是这样也让不熟悉 Tokio 底层原理的用户一不小心就掉入到坑里。

我们遇到的问题是，需要实现一个第三方库的 trait ，而这个 trait 是同步的{{< emoji ":sweat_smile:" >}}，我们无法修改这个 trait 的定义。
```rust
trait Sequencer {
    fn generate(&self) -> Vec<i32>;
}
```

我们用一个`PlainSequencer`来实现这个 trait ，而在实现 `generate`方法的时候依赖一些异步的调用（比如这里的 `PlainSequencer::generate_async`）：
```rust
impl PlainSequencer {
    async fn generate_async(&self)->Vec<i32>{
        let mut res = vec![];
        for i in 0..self.bound {
            res.push(i);
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        res
    }
}

impl Sequencer for PlainSequencer {
    fn generate(&self) -> Vec<i32> {
		self.generate_async().await
    }
}
```
这样就会出现问题，因为 `generate`是一个同步方法，里面是不能直接 await 的。
```latex
error[E0728]: `await` is only allowed inside `async` functions and blocks
  --> src/common/tt.rs:32:30
   |
31 | /     fn generate(&self) -> Vec<i32> {
32 | |         self.generate_async().await
   | |                              ^^^^^^ only allowed inside `async` functions and blocks
33 | |     }
   | |_____- this is not `async`
```
我们首先想到的是，tokio 的 runtime 有一个 `Runtime::block_on`[[1]](https://docs.rs/tokio/latest/tokio/runtime/struct.Runtime.html#method.block_on) 方法，可以同步地等待一个 future 完成。
```rust
impl Sequencer for PlainSequencer {
    fn generate(&self) -> Vec<i32> {
        RUNTIME.block_on(async{
            self.generate_async().await
        })
    }
}

#[cfg(test)]
mod tests{
	#[tokio::test]
    async fn test_sync_method() {
        let sequencer = PlainSequencer {
            bound: 3
        };
        let vec = sequencer.generate();
        println!("vec: {:?}", vec);
    }
}
```
编译通过，但是运行时直接报错：
```latex
Cannot start a runtime from within a runtime. This happens because a function (like `block_on`) attempted to block the current thread while the thread is being used to drive asynchronous tasks.
thread 'tests::test_sync_method' panicked at 'Cannot start a runtime from within a runtime. This happens because a function (like `block_on`) attempted to block the current thread while the thread is being used to drive asynchronous tasks.', /Users/lei/.cargo/registry/src/github.com-1ecc6299db9ec823/tokio-1.17.0/src/runtime/enter.rs:39:9
```
提示不能从一个执行中一个 runtime 直接启动另一个异步 runtime。

看来 Tokio 为了避免这种情况特地在入口做了检查。
既然不行那我们就再看看其他的异步库是否有类似的异步转同步的方法。果然找到一个 `futures::executor::block_on`[[2]](https://docs.rs/futures/0.2.0/futures/executor/fn.block_on.html)。

```rust
impl Sequencer for PlainSequencer {
    fn generate(&self) -> Vec<i32> {
        futures::executor::block_on(async {
            self.generate_async().await
        })
    }
}
```

编译同样没问题，但是运行时代码直接直接 hang 住不返回了。
```latex
cargo test --color=always --package tokio-demo --bin tt tests::test_sync_method --no-fail-fast -- --format=json --exact -Z unstable-options --show-output      
   Compiling tokio-demo v0.1.0 (/Users/lei/Workspace/Rust/learning/tokio-demo)
    Finished test [unoptimized + debuginfo] target(s) in 0.39s
     Running unittests src/common/tt.rs (target/debug/deps/tt-adb10abca6625c07)
{ "type": "suite", "event": "started", "test_count": 1 }
{ "type": "test", "event": "started", "name": "tests::test_sync_method" }
```

明明 `generate_async`方法里面只有一个简单的 sleep 调用，但是为什么 future 一直没完成呢？
并且吊诡的是，同样的代码，在 `tokio::test`里面会 hang 住，但是在 `tokio::main`中则可以正常执行完毕：
```rust
#[tokio::main]
pub async fn main() {
    let sequencer = PlainSequencer {
        bound: 3
    };
    let vec = sequencer.generate();
    println!("vec: {:?}", vec);
}
```
执行结果：
```latex
cargo run --color=always --package tokio-demo --bin tt
    Finished dev [unoptimized + debuginfo] target(s) in 0.05s
     Running `target/debug/tt`
vec: [0, 1, 2]
```

> 其实当初真正遇到这个问题的时候定位到具体在哪里 hang 住并没有那么容易。真实代码中 async 执行的是一个远程的 gRPC 调用，当初怀疑过是否是 gRPC server 的问题，动用了网络抓包等等手段最终发现是 client 侧 的问题。这也提醒了我们在出现 bug 的时候，抽象出问题代码的执行模式并且做出一个最小可复现的样例（Minimal Reproducible Example）是非常重要的。

## Catchup
凭着对 Rust 异步 runtime 的基本了解，我大概知道类似 Tokio 这样的异步 runtime 是一个 executor+scheduler+reactor 的模型。其中：

- executor：在计算资源（在 std 环境下就是操作系统的 thread，嵌入式环境下则没有 thread 抽象）上执行真正的异步任务；
- scheduler：负责维护一个异步任务的 FIFO 并且负责任务在不同 executor 之间调度；
- reactor：抽象底层阻塞 IO，提供非阻塞事件监听和唤醒的功能（类似 epoll 那样）。

Rust 中的一个异步代码块本质上是一个 future，
```rust
async {
    println!("hello");
}
```
其是不会直接执行的，只有将其 spawn 到异步的 runtime 里面才会真正封装成一个任务交给 executor 执行。Runtime 有一套机制去唤醒异步任务，检查 future 的状态是否为 ready 等等。
## 问题分析
回顾完背景知识，我们再看一眼方法的实现：
```rust
fn generate(&self) -> Vec<i32> {
    futures::executor::block_on(async {
        self.generate_async().await
    })
}
```

调用 `generate`方法的肯定是 Tokio 的 executor，那么 block_on 里面的 `self.generate_async().await`这个 future 又是谁在 poll 呢？一开始我以为，`futures::executor::block_on`会有一个内部的 runtme 去负责 `generate_async`的 poll。于是点进去[代码](https://docs.rs/futures-executor/0.3.6/src/futures_executor/local_pool.rs.html#77-104)（主要是`futures_executor::local_pool::run_executor`这个方法）：

```rust
fn run_executor<T, F: FnMut(&mut Context<'_>) -> Poll<T>>(mut f: F) -> T {
    let _enter = enter().expect(
        "cannot execute `LocalPool` executor from within \
         another executor",
    );

    CURRENT_THREAD_NOTIFY.with(|thread_notify| {
        let waker = waker_ref(thread_notify);
        let mut cx = Context::from_waker(&waker);
        loop {
            if let Poll::Ready(t) = f(&mut cx) {
                return t;
            }
            let unparked = thread_notify.unparked.swap(false, Ordering::Acquire);
            if !unparked {
                thread::park();
                thread_notify.unparked.store(false, Ordering::Release);
            }
        }
    })
}
```

立刻嗅到了一丝不对的味道，虽然这个方法名为 `run_executor`，但是整个方法里面貌似没有任何 spawn 的操作，只是在当前线程不停的循环判断用户提交的 future 的状态是否为 ready 啊！！！！

这意味着，当 Tokio 的 runtime 线程执行到这里的时候，会立刻进入一个循环，在循环中不停地判断用户的的 future 是否 ready，如果还是 pending 状态，则将当前线程 park 住。假设，用户 future 的异步任务也是交给了当前线程去执行，`futures::executor::block_on`等待用户的 future ready，而用户 future 等待 `futures::executor::block_on`释放当前的线程资源，那么不就死锁了？
很有道理啊，立刻验证一下。既然不能在当前 runtime 线程 block，那就重新开一个线程 block：
```rust
impl Sequencer for PlainSequencer {
    fn generate(&self) -> Vec<i32> {
        let bound = self.bound;
        std::thread::spawn(move || {
            futures::executor::block_on(async {
                // 这里使用一个全局的 runtime 来 block
                RUNTIME.block_on(async {
                    let mut res = vec![];
                    for i in 0..bound {
                        res.push(i);
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                    res
                })
            })
        }).join().unwrap()
    }
}
```

果然可以了。
```rust
cargo test --color=always --package tokio-demo --bin tt tests::test_sync_method --no-fail-fast -- --format=json --exact -Z unstable-options --show-output
    Finished test [unoptimized + debuginfo] target(s) in 0.04s
     Running unittests src/common/tt.rs (target/debug/deps/tt-adb10abca6625c07)
vec: [0, 1, 2]
```

值得注意的是，在 `futures::executor::block_on`里面，额外使用了一个 `RUNTIME`来 spawn 我们的异步代码。其原因还是刚刚所说，这个异步任务需要一个 runtime 来驱动状态的变化，如果去掉 runtime，从一个新线程中执行我们的异步任务的话，`futures::executor::block_on`第一次 poll 我们异步任务的 future，会进入到 `tokio::time::sleep`方法调用，这个方法会判断当前执行的异步 runtime （上下文信息），而这个上下文信息是保留在 thread local 中的，在新线程中并不存在这个 thread local，从而会 panic。
```rust
called `Result::unwrap()` on an `Err` value: Any { .. }
thread '<unnamed>' panicked at 'there is no reactor running, must be called from the context of a Tokio 1.x runtime',
...
```
### `tokio::main`和 `tokio::test`
在分析完上面的原因之后，“为什么 `tokio::main`中不会 hang 住而 `tokio::test`会 hang 住”这个问题也很清楚了，他们两者所使用的的 runtime 并不一样。`tokio::main`使用的是多线程的 runtime，而 `tokio::test` 使用的是单线程的 runtime，而在单线程的 runtime 下，当前线程被 `futures::executor::block_on`卡死，那么用户提交的异步代码是一定没机会执行的，从而必然形成上面所说的死锁。
## Best practice
经过上面的分析，结合 Rust 基于 generator 的协作式异步特性，我们可以总结出 Rust 下桥接异步代码和同步代码的一些注意事项：

- 在异步代码调用（可能阻塞的）同步代码时，请使用 `tokio::task::spawn_blocking` [[3]](https://docs.rs/tokio/0.2.22/tokio/task/fn.spawn_blocking.html)
- 尽量避免在异步代码中进行大规模的 CPU 密集型计算，避免对任务调度的公平性造成影响（CPU 密集型任务可以使用 [rayon](https://docs.rs/rayon/latest/rayon/) 代替）
- 在同步代码调用异步代码的时候，使用 `futures::executor::block_on`请务必注意和 `tokio::task::spawn_blocking`（或者`std::thread::spawn`）配合使用，因为前者会阻塞当前线程。理想情况是，通过一个 blocking-dedicated executor 去调用 `futures::executor::block_on`，然后再通过 `tokio::runtime::spawn`把任务丢回给原来的 runtime 去执行。
```rust
// 如果你可以控制 generate 方法如何被调用
fn generate(&self) -> Vec<i32> {
    let bound = self.bound;
    futures::executor::block_on(async {
        RUNTIME.block_on(async {
            let mut res = vec![];
            for i in 0..bound {
                res.push(i);
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            res
        })
    })
}

// 那么你可以在调用 generate 之前使用 spawn_blocking 避免死锁
#[tokio::test]
#[tokio::test]
async fn test_sync_method() {
    let sequencer = PlainSequencer {
        bound: 3
    };
    let vec = tokio::task::spawn_blocking(move || {
        sequencer.generate()
    });
    println!("vec: {:?}", vec);
}
```

```rust
// 如果 generate 方法的调用方并不是你能控制的，那么请使用 std::thread::spawn
fn generate(&self) -> Vec<i32> {
    let bound = self.bound;
    std::thread::spawn(move ||{
        futures::executor::block_on(async {
            RUNTIME.block_on(async {
                let mut res = vec![];
                for i in 0..bound {
                    res.push(i);
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                res
            })
        })
    }).join().unwrap()
}

#[tokio::test]
async fn test_sync_method() {
    let sequencer = PlainSequencer {
        bound: 3
    };
	// 这里只是一个普通的同步方法调用
    let vec = sequencer.generate();
    println!("vec: {:?}", vec);
}
```

## 参考

- [Async: What is blocking?](https://ryhl.io/blog/async-what-is-blocking/)
- [Generators and async/await](https://cfsamson.github.io/books-futures-explained/4_generators_async_await.html)
- [Async and Await in Rust: a full proposal](https://news.ycombinator.com/item?id=17536441)
- [calling futures::executor::block_on in block_in_place may hang](https://github.com/tokio-rs/tokio/issues/2603)
- [tokio@0.2.14 + futures::executor::block_on causes hang](https://github.com/tokio-rs/tokio/issues/2376)
