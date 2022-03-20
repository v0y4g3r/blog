---
title: "理解 Rust 的 Pin 机制"
date: 2022-01-29T22:41:37+08:00
draft: false
toc: false
images:
tags: 
  - Programming
  - Rust
---

Pin 之所以难以理解，是因为其是同时涉及到移动语义、所有权、异步的一个概念。可以说，Pin 是为了解决自引用数据结构的移动问题，而这个问题在 Rust 的基于 Future 的异步编程中较为常见。

首先在文章的最开始用几句话总结下这几个概念：

- Pin：控制数据的所有权（how），让其无法移动，从而避免 self-referential 的数据结构在移动的过程中被破坏。
- Unpin：说明数据不关心被移动，即使它被移动了也不会产生悬挂指针。如果一个被 pin 住的数据的类型实现了 unpin trait，那么就可以通过这个 pin 获取被 pin 住的数据的一个可变引用，从而移动这个值（how？）。
- !Unpin：一个 Marker，告诉编译器这个数据结构不能被随意移动，从而当这个数据结构被 pin 住的时候，无法得到其可变引用。
- Pin-Projection：被 pin 的数据结构可能存在部分字段是需要同时被 pin、部分字段不需要被 pin 的。
- 为什么 Rust 的 Future 的方法签名是 `Pin<&mut self>`? 因为 Rust 的 Future 本质上就是一个通过状态机实现的 generator，genrator 是 stackless 的，也就是说 Rust 在 runtime 并不会为每个 generator 维护上下文的状态，这些状态都是通过编译器的黑魔法变成 future 里面的数据。而 future 有可能会被传递、移动。Rust 所生成的 future 里面的数据存在 self-referential 的情况，那么在 future 被移动的时候，这些 self-referential 的指针就会变成野指针，从而导致异常。

## Catch up: Rust 中的数据移动

- 赋值、传参、返回：这个是最常见的。
- receiver 为`self`的方法调用：为什么数据结构上方法调用也有可能需要移动呢？一个典型的例子就是 `Vec#push`，调用之后可能会导致内部数组扩容从而被移动到新的内存位置。
- `std::mem::replace`：通过一个可变引用来移动


## Self-reference
我们来构建一个存在自我引用的数据结构：
```rust
pub struct ParserContext {
    buf: Vec<u8>,
    parsed: Option<Parsed>,
}

pub struct Parsed<'a> {
    buf: &'a Vec<u8>,
    result: String,
}
```
可以看到 `ParsedContext`拥有一个字符数组 `buf`和 解析的结果：`Parsed`。而 `Parsed`内部包含一个对字符数组 `buf`的引用（先不考虑这样的数据结构是否必要合理）。

{{% img-width width="50%" %}}
![image.png](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/rust-self-referential-data.svg)
{{% /img-width %}}

{{% img-title %}}
数据引用结构
{{% /img-title %}}



这样的 `ParserContext`显然是存在一些问题的。假设由于各种原因，`ParserContext`的内存被移动了，那么就会造成悬垂引用，可以看下图：



{{% img-width width="50%" %}}
![image.png](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/rust-move-a-self-referential.svg)
{{% /img-width %}}
{{% img-title %}}
移动后的数据结构
{{% /img-title %}}


在 ParserContext 被移动之后，`ParserContext#buf`被移动了 `0xDCBA`，但是 `ParserContext#parsed#buf`引用指向的还是 `0xABCD`这个无效的地址。

我们把这种字段中存在一个指针指向自身或者自身一部分的数据结构称作自引用（self-referential）数据结构。自引用数据结构之所以需要单独提及，是因为自引用数据结构的值移动操作需要特殊处理。

Rust 处理自引用数据结构的方法，是引入 `Pin`语义来防止其被随意移动。


## How Pin works
当你把一个值放进 Pin 中，你就无法再获取这个值的可变引用。这样就无法通过赋值、传参、返回、方法调用、`std::mem::replace` 这些方法来移动值了。当然也有例外，当你明确地知道被 Pin 包裹的值不会再被移动，那可以通过 unsafe 的方法来获取它的可变引用。

## How async code compiles
举个例子
```rust
async fn foo(s: &mut dyn AsyncRead+AsyncWrite) {
    let mut buf=[0; 1024];
	tokio::io::read(s, &mut buf[..]).await;
}

// 上面的代码会被编译器生成下面的样子 

fn foo(s: &mut dyn AsyncRead+AsyncWrite) -> FooFuture<()>{
	//...
}

// 当 foo 返回的 future 第一次被 poll 的时候,会生成一个新的 ReadFuture 设置到 FooFuture 的
// readFuture 字段中
struct ReadFuture<'a> {
	buf: &'a mut [u8];
    s: &'a mut dyn AsyncRead
}

// foo 函数返回的 future，是一个存在 self-reference 的结构—— buf的所有权在 FooFuture，
// FooFuture 包含一个 readFuture，readFuture 包含一个 buf 的指针
struct FooFuture<'a> {
    buf: [u8: 1024];
	readFuture: ReadFuture<'a>
}
```
可以看到最终 foo 返回的 future 是一个 self-reference 的结构。
由于 Rust 的 future 是通过不断地被 poll 从而驱动状态机的状态流转的，foo 函数返回的这个 self-referential future 如果会被移动（比如在赋值、传参、数组扩缩容等情况下），那么这个 self-referential 的数据结构就会被破坏，从而导致异常。

Rust 的 future 的特性：

- Future 刚刚创建出来的时候，移动它是安全的：因为没有被 poll 过，self-referential 的结构还没有形成；
- Future 第一次被 poll 之后，移动这个 future 就不再是是安全的：因为跨越不同的 yield point 之间，一定会导致生成嵌套的 self-refenrential future。


我们来看 Future 的签名:
```rust
pub trait Future {
    fn poll(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Self::Output>;
}
```
可以看到，poll 方法的 self 的类型是：`Pin<&mut Self>`，这就意味着，调用一次 poll 之后，self 的所有权就 somehow 被这个 `Pin`获取了，持有 future 对象的代码无法再通过任何办法获取到 future 的所有权，也就无法移动这个 future。

这里也有一点需要注意下，持有这个 future 的对象如何去 poll ？
```rust
let f: FooFuture = foo();

f.poll(); // x: 这里不能直接调用,因为这里的 f 的类型是 FooFuture，也就是 Self

let p = Pin::new(&mut f); // p 的类型是：Pin<&mut FooFuture> 
p.poll(); // 这才是符合poll 方法签名的
```

那么，假设我们通过一些 workaround 去拿到 pin 里面的值呢？
```rust
let f: FooFuture = foo();

let p = Pin::new(&mut f);
p.poll(); // p 里面的 future 已经被 poll 过了,按道理这个时候 future 不能再被移动

mem::replace(&mut *p, foo());// 视试图通过 mem::replace 移动 p  里面的future
```
其实这个时候的 mem::replace 会报错的:
```rust
impl<P: Deref<Target: Unpin>> Pin<P> {
//             ^~~~~ Deref 的目标类型必须是 Unpin   
}
```
可以看到, Pin 所实现的 Deref trait 是有类型限制的：它要求 pin 里面的指针的目标类型必须实现 Unpin Trait. 如果指针的目标类型存在 self-referential 的情况，那么它是不能被 deref 的，也就无法从 Pin 中取出原始的值从而任意移动。


> Rust’s solution to this problem rests on the insight that futures are always safe to move when they are first created, and only become unsafe to move when they are polled. A future that has just been created by calling an asynchronous function simply holds a resumption point and the argument values. These are only in scope for the asynchronous function’s body, which has not yet begun execution. Only polling a future can borrow its contents.


`Pin<&mut Self>` 就是为了确保 Future 对象自己不会被移动。

`Unpin`：代表对象不存在 self-reference 等情况，可以被随意移动。大部分 Rust 标准库里面的数据结构都是 Unpin 的。
`!Unpin`：作为一个 marker,告诉 rust 编译器这个数据结构是无法被随意移动的,一旦这个数据结构进入到 Pin 中，就不能从 Pin 中重新获取数据的所有权。


# 一个 self-referential 的例子
```rust
use std::pin::Pin;

#[derive(Debug)]
pub struct ParserContext {
    // buf 不能移动
    buf: Pin<Vec<u8>>,

    // parsed 这个字段可以随意移动
    parsed: Option<Parsed>,
}

#[derive(Debug)]
pub struct Parsed {
    buf: Pin<Vec<u8>>,
    result: String,
}

impl ParserContext {
    pub fn do_parse(self: Pin<&mut Self>) {
        // do_parse 只修改 parsed，而 parsed 的移动
        let this = unsafe {
            self.get_unchecked_mut()
        };

        this.parsed = Option::Some(Parsed {
            buf: this.buf.clone(),
            result: String::from_utf8_lossy(&this.buf[0..this.buf.len()]).to_string(),
        });
    }
}

fn main() {
    let mut vec = Vec::new();
    vec.push(b'h');
    vec.push(b'e');
    vec.push(b'l');
    vec.push(b'l');
    vec.push(b'o');
    let pin = Pin::new(vec);
    let mut context = ParserContext {
        buf: pin,
        parsed: Option::None,
    };

    let pinned = Pin::new(&mut context);
    pinned.do_parse();

    match context.parsed {
        None => {
            println!("Not expect to reach here.")
        }
        Some(p) => {
            println!("Parse success");
            println!("{}", p.result);
        }
    }
}
```

如果用 pin_project 来改写
```rust
use std::pin::Pin;

#[pin_project::pin_project]
pub struct ParserContext {
    // buf 不能移动，因此使用 pin 来标识
    #[pin]
    buf: Vec<u8>,

    // parsed 这个字段可以随意移动
    parsed: Option<Parsed>,
}

#[derive(Debug)]
#[pin_project::pin_project]
pub struct Parsed {
    #[pin]
    buf: Vec<u8>,
    result: String,
}

impl ParserContext {
    pub fn do_parse(self: Pin<&mut Self>) {
        let this = self.project();
        let _ = std::mem::replace(this.parsed, Option::Some(Parsed {
            buf: this.buf.clone(),
            result: String::from_utf8_lossy(&this.buf[0..this.buf.len()]).to_string(),
        }));
    }
}

fn main() {
    let mut vec = Vec::new();
    vec.push(b'h');
    vec.push(b'e');
    vec.push(b'l');
    vec.push(b'l');
    vec.push(b'o');

    let mut context = ParserContext {
        buf: vec,
        parsed: Option::None,
    };

    let pinned = Pin::new(&mut context);
    pinned.do_parse();

    match context.parsed {
        None => {
            println!("Not expect to reach here.")
        }
        Some(p) => {
            println!("Parse success");
            println!("{}", p.result);
        }
    }
}
```
