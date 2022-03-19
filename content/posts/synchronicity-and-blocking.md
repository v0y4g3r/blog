---
title: "同步/异步和阻塞/非阻塞"
date: 2019-03-19T22:41:37+08:00
draft: false
toc: false
images:
tags: 
  - Programming
---

同步/异步以及阻塞/非阻塞这几个概念网络上的解释很多，不少解释试图通过举拿快递/去书店买书等例子来解释这些概念。乍一看非常通俗易懂，但是任何一个概念，它的信息量是一定的，如果举例子能够让人更加容易明白，那么一定损失了相当程度的信息量。

> “薛定谔的猫”可以帮助人们更好地理解不确定性原理，但是不确定性原理远不只是一个思想实验的内涵。

## 模型

所有的 IO 都可以抽象成请求方（client）和资源提供方（server）两方的交互。从client来看:

-   如果请求发起之后，client总是等到收到响应再继续执行接下来的任务，则称为阻塞(blocking)
-   如果client发出请求之后，不等到响应就直接继续其他任务，则成为非阻塞(non-blocking)
-   如果client需要自己去从server处以某种方式主动获取结果，则称为同步(synchronous)
-   如果client发起请求时指定了某种通知机制，server回复响应时直接将结果通过这个通知机制通知client处理，则称为异步(asynchronous)

> 阻塞和非阻塞关心的是请求发起者在发起请求后的行为，而同步异步关心的是对响应的控制权和主动权。异步相比同步方式而言是对控制权的反转，请求方被动地获取结果。

将同步/异步和阻塞/非阻塞两两组合可以得到四种IO模型:

-   同步阻塞: 最经典的编程模型

```python
response = socket.socket().connect(("127.0.0.1",8080)).recv(1024)
print(str(response,encoding='utf8'))
```

上面的代码一旦连接到server后，python解释器会一直阻塞直到接收到结果，然后再把结果打印出来。这个过程当中系统会在阻塞的地方进行上下文切换，等到数据就绪内核将唤醒python线程，由python将kernel buffer当中的数据复制到用户空间的buffer。在互联网的早期，CGI（Common Gateway Interface）往往就是采用这种IO模型，当然程序员不会蠢到让请求按先来后到的顺序排队一个一个处理，而是通过多进程的方式解决IO阻塞的问题。但是进程切换会导致CPU的缓存以及页表的TLB(Translation Lookaside Table)失效，导致一段时间内的访存非常低效，因此开销很大。逐步地多线程代替了多进程称为同步编程。创建/切换线程的代价虽然比进程小但是一旦并发量上升仍然是很大的开销，因此出现了线程池，通过缓存已经使用过的线程来降低创建线程的开销。

-   同步非阻塞 Client 发起请求后立刻返回，并且获取到一个关于已经发出的这个请求的句柄(文件描述符等抽象形式)，然后继续处理其他事务，并且通过查询这个句柄的状态（`select`）决定是否对事件(可读/出错)做出相应处理。如果 client 发现句柄可读了，那么这个时候再去调用`read()`方法一定不会阻塞。同步非阻塞通常又称为 IO 复用(IO Multiplexing)，因为在这种模型下，client 可以同事对多个 IO 进行监视，然后把事件分发给相应IO的处理程序。
-   异步阻塞 效果等同于同步阻塞。 因为 client 都已经阻塞了，同步或者异步的信号通知机制并没有区别。大部分情况下不作讨论。
-   异步非阻塞 client 发起的请求为 server 指明了回调机制(系统级的signal又或者是应用程序级别的HTTP回调URL)，然后client去继续处理其他事务。等待server有消息返回时，server完成消息的打包，对齐等操作，通过client指明的通知机制通知client。Windows提供的系统级异步IO是IOCP，而Linux提供的接口为AIO(非常难用)。
    

> 除了这四种模型，Linux还实现了[边缘触发的信号驱动式的IO模型——SIGIO](http://davmac.org/davpage/linux/async-io.html#sigio)，但是这种模型不能用于文件的读写。

## 三层抽象

为什么上文要把IO模型抽象在C/S模型的基础上描述?因为**同样的一个系统调用，从体系结构的不同层面去看，它的IO模型不总是一致的**。 当用户的程序发起一个IO请求(比如写socket)，首先是该语言的运行时环境向操作系统发起系统调用(比如Linux下是`send`)，操作系统将需要发送的缓冲区复制到网卡的FIFO，网卡会自行选择合适的时间把包发送出去。在这个过程当中，需要仔细分析用户代码和语言runtime，runtime和操作系统，CPU和网卡这三层的调用情况。

### 硬件

首先看最底层的CPU和网卡。 显然除了高速总线上的等待之外，CPU不存在同步IO的情况，大批量的数据发送和接收总是由DMA处理，DMA完成后通过硬件中断通知CPU，这是最典型的异步非阻塞的模式。

### OS与runtime

其次是runtime和OS的交互。大部分对IO性能优化的努力都集中在这个层面。OS提供的IO一般都是通过系统调用(syscall)实现的，几乎所有系统的syscall默认都是同步阻塞，但是可以手动配置成同步非阻塞的。 由于同步非阻塞需要轮询句柄的状态，因此轮询的算法决定了IO以及事件分发的效率。 Linux系统下的Poll模型时间复杂度为O(n)，为了改善Poll的效率出现了Epoll，其时间复杂度为O(1)。 除此之外，现代操作系统一般还支持内核级别的异步IO，比如Linux下的AIO以及Windows下的IOCP（IO完成端口）。以AIO为例，需要为每一个IO创建异步IO控制块（aiocb），aiocb是一个结构体:

```c
struct aiocb {
         int aio_fildes;
         int aio_lio_opcode;
         volatile void *aio_buf;
         size_t aio_nbytes;
         struct sigevent aio_sigevent;
         ...
};
```

可以很明显看到，有一个`aio_buf`字段用于向内核指明一旦IO完成就将数据复制到`aio_buf`这个地址。 Linux AIO和Epoll相比仍然不够成熟。 除了系统层面的努力，还有各种实现了AIO的库：[glibc AIO](https://www.gnu.org/software/libc/manual/html_node/Asynchronous-I_002fO.html)、[libeio](http://software.schmorp.de/pkg/libeio.html)，但是和Windows的IOCP相比，差距依然很大。

### 语言的编程风格

最后看编程语言所提供的IO模型。 通常我们所说的异步编程范式, 往往指的是这个层面的IO模型, 比如Node.js的error-first callback:

```js
request('url', function(err, data){
    if(err) return console.log(err);
    process(data);
});
```

在用户的function里面所处理的`data`既不是socket的字节流，又不是HTTP报文，而是转换为JS对象的HTTP报文体。 这是因为Node.js的runtime为我们做好了data的处理和对齐, 把处理好的数据丢给用户的程序, 因此对于用户而言这样的**编程风格**是异步的。 callback是最直观的异步编程范式，但是并不是最好的。一旦多个IO请求存在依赖关系，就容易出现（也是Node.js刚出来时最让人诟病的一点）callback hell:

```js
request('url1', function(err, data1){
    if(err) return console.log(err);
    request(data1.url, function(err, data2){
        if(err) return console.log(err);
        request(data2.url, function(err, data3){
            if(err) return console.log(err);
            process(data3)
        }
    }
});
```

相互依赖的IO请求使回调出现嵌套，不仅使代码横向增长，而且让异常除了变得非常艰难。 为了解决这个问题，Javascript社区开发出了很多替代方案，比如ES6的`Promise`和ES7的`async/await`。

```js
request(url1)
    .then(data1=>{
        return request(data1.url)    
    })
    .then(data2=>{
        return request(data2.url)    
    })
    .then(data3=>{
        process(data3);
    })
    .catch(e=>{
        console.log(e);
    })
```

`Promise`将回调转换成了链式调用的API，但是JS社区仍不满意，因为Promise最大的问题在于它具有传染性，如果函数2依赖于函数1的结果，而函数1是回调式的，那么必须将函数1转换为Promise的才行。这就是为什么几乎所有的JS Promise库都自带了`promisify`功能。因此又开发出了`async/await`

```js
(async()=>{
    let data1 = await request(url1);
    let data2 = await request(data1.url);
    let data3 = await request(data2.url);
    process(data3);
})();
```

JavaScript的`async/await`是基于`generator`的，有兴趣的可以自己去研究。 同理，Python的`asyncio`也是基于协程和`generator`的。

## 常见问题

Q: Node.js是异步IO吗? A: 系统级别的异步性取决于Node.js的实现。Node.js底层所依赖的`libuv`(从Node.js 0.9.0开始)在Linux上基于Epoll,在Windows上基于`IOCP`.Epoll属于同步非阻塞IO(然而epoll暴露出来的接口是阻塞的, 因为`epoll_wait()`方法会等待一个事件的发生然后再分发事件), IOCP属于异步非阻塞IO. Node.js的`libuv`封装了这些底层的差异性, 提供了一个通用的事件循环。 Node.js在libuv的基础上提供了一套异步的编程接口(注意区别于异步IO)。 Q: Linux如何实现内核层面IO? A: 使用Linux AIO

## 参考链接

1.  [IO Demystified](https://chamibuddhika.wordpress.com/2012/08/11/io-demystified/)
2.  [怎样理解阻塞非阻塞与同步异步的区别？](https://www.zhihu.com/question/19732473)