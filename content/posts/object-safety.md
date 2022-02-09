---
title: "Object Safety"
date: 2022-02-09T21:57:33+08:00
draft: false
toc: false
images:
tags: 
  - Rust
---

Rust 的 RFC 上只给出了 object-safety 的定义，但是没有解释为何在满足这些条件的时候 trait 是 object safe 的，以及为啥需要 object safety。下面就尝试解释一下。
​

为什么需要 object safety？
​

Rust 通过 trait object 提供了类型擦除、动态分派的能力，但是这个能力是有限制的，不是所有的 trait 都能自动生成实现。Trait object 本质上是对某个 trait 的自动默认实现，包括一个数据区和一个方法表。Object-safety 本质是为了保证 Rust 编译器能够为某个 trait 生成自动实现。
​

![image.png](https://cdn.nlark.com/yuque/0/2022/png/139136/1644393130537-0059bb37-3cd3-451f-b374-428184f97927.png)
_Trait object 的内存布局_

> - [Where Self Meets Sized: Revisiting Object Safety](https://huonw.github.io/blog/2015/05/where-self-meets-sized-revisiting-object-safety/)

​

首先是关于 trait object 的，一个 trait 是对象安全的，当且仅当它满足一下所有条件：

- trait 的类型不能限定为 `Self: Sized`1️⃣；
- trait 中所定义的所有方法都是 object-safe 的2️⃣。

​

接下来是关于方法的
一个方法是对象安全的，当且仅当这个方法满足下面任意一条特性：

- 方法 receiver 的类型限定是 `Self: Sized`3️⃣；或者
- 满足以下所有条件：
   - 方法不能有泛型参数4️⃣；且
   - receiver 类型必须是 Self 或者可以解引用为 Self 的引用类型5️⃣。目前只包括`self`/ `&self` / `&mut self`/ `self: Box<Self>`。以后可能也会扩展到 `Rc<Self>`等等。
   - `Self`类型只能用作 receiver 6️⃣

​

1️⃣ 也就是说，如下的 trait 是不能用作 trait object 的。
```rust
trait Test: Sized {
	fn some_method(&self);
}
```
为什么trait 的方法的 receiver 不能限定为 `Self: Sized`？因为 trait object 本身是动态分派的，编译期无法确定 trait object 背后的 Self 具体是什么类型，也就无法确定 Self 的大小。如果这个时候 trait object 的方法又要求 Self 大小可确定，那就互相矛盾了。需要注意的是，trait object 自身的大小是可确定的，因为其只包括指向数据的指针和指向 vtable 的指针而已。
​

2️⃣ 要求 trait 所有的方法都是对象安全的也是为了确保动态分派的时候能够正确从 vtable 中找到方法进行调用。
​

3️⃣ 由于 trait object 自身是 Unsized，如果方法限定了`Self: Sized`，那么一定无法通过 trait object 去调用。也就不会导致动态分派的 object safety 问题，因此一个限定了 `Self: Sized`的 trait 方法也被认为是 object-safe 的。
​

> - [Why does a generic method inside a trait require trait object to be sized? - Stack Overflow](https://stackoverflow.com/questions/42620022/why-does-a-generic-method-inside-a-trait-require-trait-object-to-be-sized)
> - [A method marked where Self: Sized on a trait should not be considered during object safety checks #22031](https://github.com/rust-lang/rust/issues/22031)

​

4️⃣ 如果方法不限定 `Self: Sized` ，就意味着那么这个方法首先不能有泛型参数。如果有泛型参数，那么 vtable 中的方法列表大小是难以确定的。当然如果非要做，在编译期，rust 编译器可以拿到 trait 的所有具体实现，然后为每一个具体实现在 vtable 生成一个特化的方法项。但是首先这会大大降低编译速度，其次也会引入极大的复杂性。因此 Rust 的 trait object 直接禁止了这种使用场景。
​

> [Why are trait methods with generic type parameters object-unsafe?](https://stackoverflow.com/questions/67767207/why-are-trait-methods-with-generic-type-parameters-object-unsafe)

​

5️⃣ 如果方法没有 receiver，那么使用 trait object 毫无意义，因为这个方法的调用根本不需要 trait object 里面的 data 指针。
​

6️⃣ 假设 trait 定义了这么一个方法：
```rust
trait Test {
	fn duplicate(self: Self) -> Self
}
```
那么这个 trait 的 duplicate 方法要求返回的类型和方法 receiver 的类型是一样的。如果 Trait 是静态分派，那么在编译器就可以确定所有可能的方法签名。比如结构体 A、B 实现了 Test trait，那么 duplicate 方法所有可能的签名是：
```rust
fn duplicate(self: A) -> A;
fn duplicate(self: B) -> B;
```
而在动态分派下，从一个 trait object 发起方法的调用，也就无法在编译期约束不同位置的 Self 类型都是一致的，完全有可能出现 下面的情况。
```rust
fn duplicate(self: B) -> A;
```


- [https://rust-lang.github.io/rfcs/0255-object-safety.html](https://rust-lang.github.io/rfcs/0255-object-safety.html)

