---
title: "三个字母引发的惨案"
date: 2023-02-19T18:28:33+08:00
draft: false
toc: true
images:
issueNumber: 2
tags: 
- Rust
- Programming

---

## 问题
在 [feat: compaction integration - GreptimeTeam/greptimedb #997](https://github.com/GreptimeTeam/greptimedb/pull/997) 中，我们尝试把 table compaction 作为 flush 的后置任务触发，因此需要为 `FlushJob`增加一个 callback，因为涉及到异步操作，所以这个 callback 的定义是：
```rust
pub type FlushCallback = Pin<Box<dyn Future<Output = ()> + Send + 'static>>;

pub struct FlushJob<S: LogStore> {
    ...
    pub on_success: Option<FlushCallback>,
}
```
然后在完成 flush 后调用 callback：
```rust
#[async_trait]
impl<S: LogStore> Job for FlushJob<S> {
    async fn run(&mut self, ctx: &Context) -> Result<()> {
        let file_metas = self.write_memtables_to_layer(ctx).await?;
        self.write_manifest_and_apply(&file_metas).await?;
        if let Some(cb) = self.on_success.take() {
            cb.await;
        }
        Ok(())
    }
}
```
可惜编译器无情地给出了 error：
```rust
error: future cannot be sent between threads safely
   --> src/storage/src/flush.rs:250:58
    |
250 |       async fn run(&mut self, ctx: &Context) -> Result<()> {
    |  __________________________________________________________^
251 | |         let file_metas = self.write_memtables_to_layer(ctx).await?;
252 | |         self.write_manifest_and_apply(&file_metas).await?;
253 | |
...   |
257 | |         Ok(())
258 | |     }
    | |_____^ future created by async block is not `Send`
    |
    = help: the trait `Sync` is not implemented for `(dyn futures_util::Future<Output = ()> + std::marker::Send + 'static)`
note: future is not `Send` as this value is used across an await
   --> src/storage/src/flush.rs:251:60
    |
251 |         let file_metas = self.write_memtables_to_layer(ctx).await?;
    |                          ----                              ^^^^^^ - `self` is later dropped here
    |                          |                                 |
    |                          |                                 await occurs here, with `self` maybe used later
    |                          has type `&FlushJob<S>` which is not `Send`
help: consider moving this into a `let` binding to create a shorter lived borrow
   --> src/storage/src/flush.rs:251:26
    |
251 |         let file_metas = self.write_memtables_to_layer(ctx).await?;
    |                          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    = note: required for the cast from `[async block@src/storage/src/flush.rs:250:58: 258:6]` to the object type `dyn futures_util::Future<Output = std::result::Result<(), error::Error>> + std::marker::Send`

```

大概意思是说，新加入`FlushJob` 的`cb`字段不是`Sync`的，导致`FlushJob::run`方法所产生的 future 不满足`Send`约束。
> 这一点倒是容易理解，因为我们对 FlushCallback 的定义`Pin<Box<dyn Future<Output=xxx> + Send>>`并未带上 `Sync`trait，通常我们也不应该要求一个 future 是`Sync`的，因为 future 的定义中唯一一个方法的 receiver 是 `self: Pin<&mut Self>`，不存在对 self 的 shared reference，所以不应该要求 future 满足`Sync`。

```rust
pub trait Future {
    fn poll(self: Pin<&mut Self>, 
            cx: &mut Context<'_>) -> Poll<Self::Output>;
}

```

因此，除了为 `FlushCallback`强行加上`Sync`约束外，我们更应该想一想为什么编译器会要求`FlushCallback: Sync`。
## MRE
为了方便排查问题，我们把不相关的代码逻辑去掉，用一段最简单的代码来复现这个问题。
```rust
use std::future::Future;
use std::pin::Pin;

#[async_trait::async_trait]
pub trait Job: Send {
    async fn run(&mut self) -> Result<(), ()>;
}

type Callback = Pin<Box<dyn Future<Output = ()> + Send + 'static>>;

pub struct JobImpl {
    cb: Option<Callback>,
}

impl JobImpl {
    pub async fn do_something(& self) {}
}

#[async_trait::async_trait]
impl Job for JobImpl {
    async fn run(&mut self) -> Result<(), ()> {
        self.do_something().await;
        if let Some(cb) = self.cb.take() {
            cb.await;
        }
        Ok(())
    }
}

#[tokio::main]
pub async fn main() {
    let mut job_impl = JobImpl { cb: None };
    job_impl.run().await.unwrap();
}

```

在 [Rust Playground](https://play.rust-lang.org/?version=stable&mode=debug&edition=2021&gist=90f5a253a0a6e5cef0e659e42fa1a193) 中编译运行这段代码可以看到类似的报错。

现在代码里面的魔法只剩下了`async_trait`这个 proc macro。为了进一步简化代码，我们可以手动把这个宏展开：
```rust
$ cargo expand mre
    Checking lance-demo v0.1.0 (/Users/lei/Workspace/Rust/mre)
    Finished dev [unoptimized + debuginfo] target(s) in 0.23s

mod mre {
    use std::future::Future;
    use std::pin::Pin;
    
    pub trait Job: Send {
        fn run(&mut self) -> 
            Pin<Box<dyn Future<Output = Result<(), ()>> + Send + '_>>;
    }
    
    type Callback = Pin<Box<dyn Future<Output = ()> + Send + 'static>>;
    
    pub struct JobImpl {
        cb: Option<Callback>,
    }
    
    impl JobImpl {
        pub async fn do_something(&self) {}
    }
    
    impl Job for JobImpl {
        fn run(&mut self) -> Pin<Box<dyn Future<Output = Result<(), ()>> + Send + '_>> {
            let mut __self = self;
            Box::pin(async move {
                JobImpl::do_something(__self).await;
                if let Some(cb) = __self.cb.take() {
                    cb.await;
                }
                Ok(())
            })
        }
    }
}
```
可以看到 `JobImpl::run`方法返回的 future 里面只包含了对 self 的引用 `__self`。因此 future 不满足`Send`约束，也就是`__self`不满足`Send`约束，而 `__self`的类型是什么呢？根据`JobImpl::run`的 receiver 很显然是 `&mut self`。

Hmmm... `Send`/`Sync`/`&mut T`/`&T`似乎让人想起来刚刚开始学 Rust 的时候一些古早记忆，查到这里不妨再复习一下。

## 一点点小知识🤏🏻
`Send` 和 `Sync` 都是用于描述 thread-safety 的 marker trait.

- `Send`指的是某个数据类型可以被安全地转移到另一个线程 (move)
- `Sync`指的是某个数据类型可以安全地被多个线程共享不可变引用 (borrow)
> “安全地传递”指的是在保证线程安全的情况下转移所有权。那么什么情况下转移所有权是不安全的呢？举个例子，`Rc`并没有实现 `Send`，只能用作单线程内部的引用计数。`Rc` 的内部是用的 `Cell`实现内部可变性，在 drop 的时候，如果引用计数为 0，则将内部包含的数据析构掉。因为[修改引用计数](https://doc.rust-lang.org/src/alloc/rc.rs.html#2633-2635)的行为本身不是原子的，因此 move 到另一个线程之后如果进行 clone，那么可能就会导致并发问题，因此 `Rc` 不能安全地被转移所有权。

- Send 和 Sync 的绑定关系
   - `&T: Send` ⇔ `T: Sync`：要想一个数据类型的不可变引用是`Send`的，那么这个数据类型自身必须是`Sync`的，这样才能保证跨线程的只读访问是安全的；
   - `&mut T: Send` ⇔ `T: Send`：要想一个数据类型的可变引用是 `Send`的，那么这个数据类型自身也必须是`Send`的，因为跨线程共享可变引用即意味着 move 。
   - 显然，相比要求 `T: Sync`，`T: Send`是更加宽松的。

## 去掉一点糖
我们再来看看 `!Send`的 future：
```rust
fn run(&mut self) -> Pin<Box<dyn Future<Output = Result<(), ()>> + Send + '_>> {
    let mut __self = self;
    Box::pin(async move {
        JobImpl::do_something(__self).await;
        if let Some(cb) = __self.cb.take() {
            cb.await;
        }
        Ok(())
    })
}
```
既然 future 捕获的是 `JobImpl`的可变引用，那么只要 `JobImpl`是`Send`的那么 future 就一定是`Send`才对啊？哪里出了问题呢？我们再来看看 `JobImpl::do_something`的签名
```rust
impl JobImpl {
    async fn do_something(&self) {}
}
```
可以看到 `do_something`的 receiver 是 `JobImpl`的共享引用，那么`__self`自然就会被 coerce 成 `&JobImpl`。根据 `Send` 和 `Sync` 的绑定关系，如果 T 的共享引用是 `Send`，那么 T 自身必须是 `Sync`，这样就能解释为啥要求 `JobImpl: Sync`了。

仅仅是因为 coercion 吗？我们可以试试把 `JobImpl::do_something`改成同步的签名 `fn do_something(&self) {}`，结果居然是可以编译的。显然问题不仅出在 receiver，也和 async 有关。我们都知道，Rust 的 async 本质上只是一个 generator 的语法糖，对 `JobImpl::do_something`的调用会被展开成一个实现了 Generator trait 的 struct，这个 struct 捕获了`JobImpl`的共享引用，而 `JobImpl`不满足`Sync`约束，从而 genrator 不满足 `Send`约束。

因此我们只需要增加三个字母，把 `JobImpl::do_something`的 receiver 改成可变引用就行啦。

```rust
impl JobImpl {
    pub async fn do_something(&mut self) {}
    //                         ^~~~ the magic lies here
}
```
[You can try it here](https://play.rust-lang.org/?version=stable&mode=debug&edition=2021&gist=0f06bf5a9a02c8bfc93a9781462e3b4e)

## 结论
所以这个问题的本质是，在一个要求 T 的可变引用的异步上下文中，调用了一个接收 T 的共享引用的异步方法，从而导致对 T 的要求从 `Send` 升级成了 `Sync`。
其实这在做了一个复现的 demo 之后还是很容易发现的（毕竟才二三十行代码），但是在项目的一个几百行的 PR 里面就不太容易发现到底是哪里不 `Sync`了。Rust 的 async/await 语法糖用起来很方便，但是还是要理解它背后是怎么实现的，不然很容易踩坑里。
