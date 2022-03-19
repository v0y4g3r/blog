---
title: "为什么我的 Netty 应用没有响应？"
date: 2019-03-19T22:41:37+08:00
draft: false
toc: false
images:
tags: 
  - Programming
  - Java
---


> 最终问题的根本原因还是没有深入理解 Netty 的线程模型。 

想法就是等服务器端启动， bind成功后再启动client。要想监听server端bind成功的状态变化，当然第一反应就是在`server.bind().sync()`返回的`ChannelFuture`中注册一个回调函数，bind成功之后在这个回调函数中启动client就行了。那么 APP入口：

```java
public void runClientAndServer() {
        server.run().addListener((ChannelFutureListener) future -> {
             client.run();                        //this doesn't work!
//            new Thread(()->client.run()).start();   //this works!
        });
}
```

服务端：

```java
public ChannelFuture run() {
   try {
       ServerBootstrap b = new ServerBootstrap();
       b.group(bossGroup, workerGroup)
               .channel(NioServerSocketChannel
               //配置channel...
               .childHandler(new ChannelInitializer<SocketChannel>() {
                   @Override
                   public void initChannel(SocketChannel ch) throws Exception {
                       ChannelPipeline p = ch.pipeline();
                       p.addLast(workerGroup, new EchoServerHandler());
                   }
               });
       return b.bind(port).sync();//等待bind成功，返回
   } catch (NullPointerException | InterruptedException e) {
       e.printStackTrace();
       return null;
   }
}
```

客户端：

```java
public void run() {
    try {
        Bootstrap b = new Bootstrap();
        b.group(group)
                .channel(NioSocketChannel.class)
                .handler(new ChannelInitializer<SocketChannel>() {
                    @Override
                    public void initChannel(SocketChannel ch) throws Exception {
                        ChannelPipeline p = ch.pipeline();
                        p.addLast(channelHandler);
                    }
                });
        // Start the client.
        ChannelFuture f = null;
        try {
            f = b.connect(host, port).sync();
            channelHandler.sendMessage();
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
        try {
            f.channel().closeFuture().sync(); //等待客户端channel关闭
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
    } finally {
        // Shut down the event loop to terminate all threads.
        group.shutdownGracefully();
    }
}
```

看上去好像没什么问题，一切都很顺理成章。但是点击运行，server端就是收不到client发送的数据。

## debug思路

首先就是要确定TCP层面的行为，即客户端到底有没有发送TCP报文，服务器端有没有接收到。使用Wireshark进行抓包：

 ![Wireshark](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/netty-wireshark1.png) 
 
 可以明显地看到，client能够成功地把数据通过TCP交付给server，server回复的`ACK`报文段代表着数据已经到达server端TCP/IP协议栈。那么可以肯定的是server端没有能够处理这个报文。 给`DefaultChannelPipeline.fireChannelRead()`方法打上断点，发现没有进入。其实到这基本可以判断是server端负责ChannelPipeline的线程出了问题。 上VisualVM。
 
  ![VisualVM](https://cdn.jsdelivr.net/gh/RayneHwang/img-repo/netty-visual-vm.png) 
  
  一眼就看到服务器的NioEventloopGroup处于waiting状态。 ThreadDump一下：

```
"nioEventLoopGroup-2-1" #16 prio=10 os_prio=0 tid=0x00007f7350b7b000 nid=0x1533 in Object.wait() [0x00007f73022b6000]
   java.lang.Thread.State: WAITING (on object monitor)
        at java.lang.Object.wait(Native Method)
        - waiting on <0x000000076d6c9d80> (a io.netty.channel.AbstractChannel$CloseFuture)
        at java.lang.Object.wait(Object.java:502)
        at io.netty.util.concurrent.DefaultPromise.await(DefaultPromise.java:236)
        - locked <0x000000076d6c9d80> (a io.netty.channel.AbstractChannel$CloseFuture)
        at io.netty.channel.DefaultChannelPromise.await(DefaultChannelPromise.java:129)
        ...
        at pku.netlab.client.EchoClient.run(EchoClient.java:86)
        at pku.netlab.App.lambda$runClientAndServer$0(App.java:31)
        at pku.netlab.App$$Lambda$1/1521389237.operationComplete(Unknown Source)
        at....
   Locked ownable synchronizers:
        - None
```

很明显了，server端负责IO的线程，阻塞在了`client.run()`方法的`closeFuture`上，为什么会出现这种情况？？？ 根本原因在于程序入口运行server和client的这段代码：

```java
public void runClientAndServer() {
    server.run().addListener((ChannelFutureListener) future -> {
         client.run();       
    });
}
```

`client.run()`会阻塞等待直到client的channel关闭（closeFuture的存在），而`server.run()`返回的ChannelFuture的背后的线程正是server的IO线程，但是我们却偏偏作死在这个线程添加了一个阻塞的回调函数，直接导致server的所有IO事件都得不到处理。

## 解决办法

在server的回调中新开线程启动客户端即可：

```java
public void runClientAndServer() {
    server.run().addListener((ChannelFutureListener) future -> {
         new Thread(()->client.run()).start();
    });
}
```

## 总结

-   永远不要阻塞Netty应用的IO线程，否则会导致整个应用失去响应
-   `Channel.closeFuture().sync()`会导致当前线程阻塞在等待channel关闭的地方