---
title: "现代 Java 捉虫指南"
date: 2021-02-12T22:01:27+08:00
draft: false
toc: true
images: 
tags: 
  - Java
---

![](https://gw.alipayobjects.com/zos/antfincdn/Se%26jyp0zs1/fe9fd884-3cb2-4cf7-b060-cd8d704cb03e.png#crop=0&crop=0&crop=1&crop=1&id=HK8X9&originHeight=1634&originWidth=2419&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=)



{{% center_italic %}} <a href="mailto:gnu.hl@antgroup.com">gnu.hl@antgroup.com</a>  {{% /center_italic %}} 

{{% center_italic %}}
**2020-12-01**
{{% /center_italic %}} 

---

> 本文是作者 2021 年在蚂蚁内部分享时的 slides 经过脱敏之后的版本。

## 当我们排查问题的时候，我们关注什么？

横向来看:

- context/critical path/caller/callee (tracing)
- statistics/metrics (profiling)

纵向来看:

- application
- runtime
- kernel

---

## Arthas

> Arthas 是基于字节码增强的调试工具.


功能:

- 观察方法的入参/返回值/异常等数据
- 观察内存对象的值
- 跟踪方法的耗时和调用栈
- 查看类加载来源/热更新类定义

### 安装

```bash
curl -L http://start.alibaba-inc.com/install.sh | sh
```

---

### Arthas 使用方法

- 观察方法入参、返回值、异常

```
watch <class_fqcn> <method_name> "{params,returnObj,throwExp}" [condition] [-f] [-b] [-xN]
```

- 拦截指定线程执行的方法

```
watch <class_fqcn> <method_name> "{params,returnObj,throwExp}" \
  "@java.lang.Thread@currentThread().getName()=='<thread_name>'" [-f] [-b] [-xN]
```

- 在观察入参同时打印方法栈

```
watch <class_fqcn> <method_name> "{params,returnObj,throwExp, \
@java.lang.Thread@currentThread().getStackTrace()}" [condition] [-f] [-b] [-xN]
```

---

### Arthas 使用方法(cont.)

- 耗时较长的方法

```
watch <class_fqcn> <method_name> "{params,returnObj,throwExp, @java.lang.Thread@currentThread().getStackTrace()}" \
'#cost>100 [&& other_cond]' [-f] [-b] [-xN]
```

- classloading 问题

```
sc -d '<class_name>'
```

- 构造对象

```
watch com.alipay.antq.broker.processor.SendMessageProcessor sendMessage \
"{new java.lang.String(params[1].body)}" -x2 -n10
```

---

### Arthas 使用方法(cont.)

- Projection & filtering

```
watch com.alipay.antqnamesrv.core.service.broker.BrokerFileService getBrokerFiles \
    "{returnObj['FILE_CLUSTER']['antq-eu95-3.gz00b.stable.alipay.net']\
    .topicQueues.values().{ #this.{? #this.queueId==32 } }.{? #this.size()!=0 }}" -x3
```

- 观察方法执行路径

```
trace [--skipJDKMethod true|false] <class_fqcn> <method_name>
```

> N/A


---

### Arthas 使用方法(cont.)

- 制作火焰图

```
# list all events
profiler list
# profile object allocation
profiler start --event alloc -d 10
# profile lock acquire
profiler start --event lock -d 10
```

- 热更新代码

```
mc/redefine
```

N/A

---

### Arthas 的缺陷

- 启动期观测 -> `jdb` / [btrace](https://github.com/btraceio/btrace)
- 测量引入 overhead
- 注意内存问题

---

## Eclipse MAT / zprofiler

- [OQL](https://lark-assets-prod-aliyun.oss-accelerate.aliyuncs.com/lark/0/2020/png/122844/1595069971931-7bb33b65-cb9e-41a0-b1b4-8547b2c1708b.png?OSSAccessKeyId=LTAI4GGhPJmQ4HWCmhDAn4F5&Expires=1607186074&Signature=LF4bn%2FxILpoIgYCGtFBWyEjDIXE%3D&response-content-disposition=inline)
  `select * from io.netty.channel.AbstractChannelhandlerContext$11`

### Native memory issues

RSS = xmx +  MaxDirectMemory + N * xss [ + gc + code cache + metaspace ]

- case1) DirectByteBuffer 未释放->通过观察堆内的DirectMemory
- case2) `[G]ZIPInput[/Output]Stream`/`De[/In]flater` [native memory leak](https://www.evanjones.ca/java-native-leak-bug.html)
- case3) Netty<= 4.0.24 [epoll native memory leak](https://github.com/netty/netty/pull/3844)
- case4) [JDK-8164293:HotSpot leaking memory](https://bugs.java.com/bugdatabase/view_bug.do?bug_id=JDK-8164293) (fixed [@8u152) ](/8u152) ) 

---

## sa-jdi / clhsdb

> Off-process vs. in-process instrumentation

- sa: serviceability agent
- clhsdb: command-line hotspot debugger
- sa-jdi 提供了获取 JVM 内部数据结构的编程接口
- sa-jdi 不仅可以 attach 活着的进程, 也可以分析 coredump
- `jstack`/`jstat`等工具均提供了基于 attach api(tools.jar) 和 sa-jdi(sa-jdi.jar)的实现
- [借HSDB来探索HotSpot VM的运行时数据](https://www.iteye.com/blog/rednaxelafx-1847971)

```bash
ls $JAVA_HOME/lib
java -cp $JAVA_HOME/lib/sa-jdi.jar sun.jvm.hotspot.CLHSDB
```

---

## sa-jdi / clhsdb(cont.)

##### 使用 sa-jdi 分析反射生成的类

```java
import sun.jvm.hotspot.oops.InstanceKlass;
import sun.jvm.hotspot.tools.jcore.ClassFilter;

public class MethodAccessorFilter implements ClassFilter {
    @Override
    public boolean canInclude(InstanceKlass instanceKlass) {
        return instanceKlass.getName().asString().startsWith("sun/reflect/Generated");
    }
}
```

```bash
java -classpath ".:$JAVA_HOME/lib/sa-jdi.jar" \
-Dsun.jvm.hotspot.tools.jcore.filter=MethodAccessorFilter sun.jvm.hotspot.tools.jcore.ClassDump <pid>
```

> SA-JDI is deprecated since Java9 -- [JDK-8158050](https://bugs.openjdk.java.net/browse/JDK-8158050)


---

## JFR

- 域内要求 JVM 版本 `^ajdk-8_5_10_fp2-b9`
- `-XX:+EnableJFR -XX:+FlightRecorder -XX:FlightRecorderOptions=<opt>=<val> -XX:StartFlightRecording=<opt>=<val>`
- 可分析的事件类型: 
  - Lock contention
  - Memory allocation
  - IO performance (Network/File)
  - Code execution performance
  - Garbage Collector
  - JIT performance

---

## JFR (cont.)

使用步骤

- 启动进程时增加开启 JFR 的参数
- 开始 JFR 记录 `jcmd <pid> JFR.start settings=profile name=<record_name>`
- dumpJFR 记录 `jcmd <pid> JFR.dump filename=jfr.output name=<record_name>`
- 使用 [JDK Mission Control](https://www.oracle.com/java/technologies/jdk-mission-control.html) 分析 JFR dump

---

## JFR (cont.)

参考资料

- [Continuous Production Profiling and Diagnostics](http://hirt.se/blog/)
- [Oracle Java Mission Control: The Ultimate Guide](https://www.javacodegeeks.com/2015/03/oracle-java-mission-control-the-ultimate-guide.html)

---

## Interesting Cases

- N/A
- N/A
- N/A

---

## One more thing

| Component                                     | Tool                    |
| --------------------------------------------- | ----------------------- |
| Application on runtime(Java/Node/Ruby/PHP)    | Runtime debugger,eBPF   |
| Application (native code)                     | System debugger,eBPF    |
| System libraries: /lib/*                      | ltrace(1),eBPF          |
| System call interface                         | strace(1), perf(1),eBPF |
| Network Traffic                               | tcpdump(8),eBPF         |
| Kernel: Scheduler, file systems, TCP, IP, etc | ftrace(1), perf(1),eBPF |
| Hardware: CPU internals, devicec              | perf, sar, eBPF         |


---

## Perf

- Why is the kernel on-CPU so much? What code-paths?
- Which code-paths are causing CPU level 2 cache misses?
- Are the CPUs stalled on memory I/O?
- Which code-paths are allocating memory, and how much?
- What is triggering TCP retransmits?
- Is a certain kernel function being called, and how often?
- What reasons are threads leaving the CPU?

-- Brendan Greg

---

## Perf (cont.)

`perf_event`:

-  Software events 
-  Hardware events 
-  Kernel static tracepoint events 
-  USDT 

![](https://intranetproxy.alipay.com/skylark/lark/0/2020/png/122844/1606655883925-873a4d92-9d1b-4d7d-8e24-31cd567ebd1f.png?x-oss-process=image%2Fresize%2Cw_1412#crop=0&crop=0&crop=1&crop=1&id=oFLoJ&originHeight=988&originWidth=1412&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=)

`sudo perf list` to list all available events.

---

```
# sudo perf record -e block:block_rq_issue -e block:block_rq_complete -a sleep 10
[ perf record: Woken up 1 times to write data ]
[ perf record: Captured and wrote 0.428 MB perf.data (~18687 samples) ]
# sudo perf script
        run 30339 [000] 2083345.722767: block:block_rq_complete: 202,1 W () 12984648 + 8 [0]
        run 30339 [000] 2083345.722857: block:block_rq_complete: 202,1 W () 12986336 + 8 [0]
        run 30339 [000] 2083345.723180: block:block_rq_complete: 202,1 W () 12986528 + 8 [0]
    swapper     0 [000] 2083345.723489: block:block_rq_complete: 202,1 W () 12986496 + 8 [0]
    swapper     0 [000] 2083346.745840: block:block_rq_complete: 202,1 WS () 1052984 + 144 [0]
  supervise 30342 [000] 2083346.746571: block:block_rq_complete: 202,1 WS () 1053128 + 8 [0]
  supervise 30342 [000] 2083346.746663: block:block_rq_complete: 202,1 W () 12986608 + 8 [0]
        run 30342 [000] 2083346.747003: block:block_rq_complete: 202,1 W () 12986832 + 8 [0]

                                                                            
              /---------------------------------------- #1  supervise: on-CPU cmd                                                             
             /       /--------------------------------- #2  30342: on-CPU cmd tid                                                       
            /       /     /---------------------------- #3  [000]: CPU running cmd                                                 
           /       /     /          /------------------ #4  2083346.746571: reltime                                        
          /       /     /          /                /-- #5  block:block_rq_complete: tracepoint  
         /       /     /          /                /                  /------------- #6  202,1 : storage major,minor number, ref lsblk
        /       /     /          /                /                  /    /--------- #7  IO type: W-Write,R-Read,A-ReadAheader,O-Sync,WS-Sync Write   
       /       /     /          /                /                  /    /  /------- #8  (): Block command details
      /       /     /          /                /                  /    /  /     /-- #9  12986336: storage device offset
     /       /     /          /                /                  /    /  /     /     /---- #10 +8: size of IO (in sectors)
    /       /     /          /                /                  /    /  /     /     /  /-- #11 [0]: if errors happened
supervise 30342 [000] 2083346.746571: block:block_rq_complete: 202,1 WS () 1053128 + 8 [0]
# how can I get this format?  cat /sys/kernel/debug/tracing/events/{event_cat}/{event_name}/format

perf script | awk '{ gsub(/:/, "") } $5 ~ /issue/ { ts[$6, $10] = $4 }
    $5 ~ /complete/ { if (l = ts[$6, $9]) { printf "%.f %.f\n", $4 * 1000000,
    ($4 - l) * 1000000; ts[$6, $10] = 0 } }'
```

```bash
sudo yum install -y kernel-devels
sudo yum install -y kernel-headers
sudo mount -t debugfs debugfs /sys/kernel/debug
```

---

## Using perf trace Java IO issues

```shell
sudo perf record -e block:block_rq_issue  -a -g  -p <pid> sleep 10
sudo perf report -G # No java stack info ?

sudo yum install -y gcc-c++ cmake
git clone https://github.com/jvm-profiling-tools/perf-map-agent
cd perf-map-agent && cmake . && make -j8
./bin/create-java-perf-map.sh <pid>
cd -
perf report -G # gotcha!
```

---

## Flame Graph

```
git clone https://github.com/brendangregg/FlameGraph
sudo perf script | \
    <path-to>/stackcollapse-perf.pl | \
    <path-to>/flamegraph.pl > perf-kernel.svg
```

## Reference

- [perf one-liners](http://www.brendangregg.com/perf.html#OneLiners)
- [Off-CPU Analysis](http://www.brendangregg.com/blog/2015-02-26/linux-perf-off-cpu-flame-graph.html)

---

## 内存增长的另外一种思路

- 通过`LD_PRELOAD`替换分配器为 jemalloc
- 开启 jemalloc 的泄漏分析
- 启动进程, 找到泄漏的 native 栈
- 用 `perf record -e <tp> -ag` 抓取分配的事件
- `create-java-perf-map.sh` 生成符号表
- `perf report/script` 查看访问线程

---

## eBPF/XDP

> eBPF does to Linux what JavaScript does to HTML. -- Brendan Gregg


![](https://gw.alipayobjects.com/zos/antfincdn/px8%24TS%2457N/5324708e-a7f5-44d7-963b-a569fd0b6d08.png#crop=0&crop=0&crop=1&crop=1&id=RJ0w2&originHeight=818&originWidth=1132&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=)

---

## eBPF probes

- Probes (Dynamic, Using `trap`) 
  - [k{,ret}probes](https://www.kernel.org/doc/Documentation/kprobes.txt)
  - [u{,ret}probes](https://lwn.net/Articles/499190/)
- Tracepoints (Static, predefined) 
  - [Kernel tracepoints](https://static.lwn.net/kerneldoc/trace/tracepoints.html) 
    - `cat /sys/kernel/debug/tracing/available_events`
  - [USDT](https://lwn.net/Articles/753601/) 
    - `readelf -n X.so | grep -A4 NT_STAPSDT`
    - `tplist.py -p <running_process>`

---

## eBPF vs. Perf

![](https://gw.alipayobjects.com/zos/antfincdn/d9OtRCINlq/4f7646df-bab8-4fe7-8bd8-5e7ba7005996.png#crop=0&crop=0&crop=1&crop=1&id=swEsD&originHeight=964&originWidth=1424&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=)

---

## eBPF Hello world

```python
#!/usr/bin/python
from bcc import BPF

prog = """
int hello(void *ctx) {
    bpf_trace_printk("Hello world\\n");
    return 0;
}
"""

b = BPF(text=prog)
#print(b.get_syscall_fnname("clone")) # platform-dependent syscall kprobe name
b.attach_kprobe(event="__x64_sys_clone", fn_name="hello")
#        ^~~~~~ this is a kprobe 
b.trace_print()
```

---

## BCC (BPF Compiler Collection)

> ---eBPF made simple

![](https://gw.alipayobjects.com/zos/antfincdn/ZknkdEV%24hu/68c407a8-8ce3-4fba-a037-f96f09e1fd27.png#crop=0&crop=0&crop=1&crop=1&id=oh5dT&originHeight=649&originWidth=872&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=)

---

## Use BCC to explore JVM USDT

```
readelf -n $JAVA_HOME/jre/lib/amd64/server/libjvm.so | grep -A4 NT_STAPSDT
sudo <path-to>/trace.py -p <java_pid> 'u::thread__sleep__begin'
```

---

## `bpftrace`

> one-liner eBPF tools

```bash
# list tracepoints
bpftrace -l 'tracepoint:syscalls:sys_enter_*'
# trace file open
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args->filename)); }'
# bio size dist
bpftrace -e 'tracepoint:block:block_rq_issue { @ = hist(args->bytes); }'
```

[bpftrace Reference Guide](https://github.com/iovisor/bpftrace/blob/master/docs/reference_guide.md#bpftrace-reference-guide)

---

## [Using eBPF to debug Hotspot JVM](https://github.com/AdoptOpenJDK/openjdk-build/issues/1173)

- Compile OpenJDK with tracepoints enabled
- Use BCC trace tools to trace JVM methods
- More Info ref - [Probing the JVM with BPF/BCC](https://web.archive.org/web/20161006014657/http://blogs.microsoft.co.il/sasha/2016/03/31/probing-the-jvm-with-bpfbcc/)/[Enable USDT probes for eBPF tracing on Linux #1173

](https://github.com/AdoptOpenJDK/openjdk-build/issues/1173)

## eBPF caveats and limitations

- Kernel requirement: `^4.4`
- Byte code instruction size < 4096
- No control loop

---

## eBPF & XDP(eXpress Data Path)

Two ways toward kernel bypass

- kernel in userspace 
  - [DPDK](https://www.dpdk.org/)
  - [Netmap](https://github.com/luigirizzo/netmap)
- user code in kernel 
  - XDP

XDP Operating modes

-  Native mode 
   - Play with DMA buffer
   - NO SKB ALLOCATON
   - Least overhead
   - Need driver modification
-  SKB mode 
   - From `netif_receive_skb()`
   - After SKB and DMA allocation
   - More instructions
   - Driver-Indepent

---

## XDP(cont.)

- Flannel: L2(IP Overlay)
- Calico: L3(BGP)
- Cilium: L3/4/7 (eBPF/XDP) 
  - [GKE2 data plane](https://cloud.google.com/blog/products/containers-kubernetes/bringing-ebpf-and-cilium-to-google-kubernetes-engine)

![](https://gw.alipayobjects.com/zos/antfincdn/SaD3%26t15mG/ab6b1bf1-eacf-49d5-9193-e1adf70c19a7.png#crop=0&crop=0&crop=1&crop=1&id=iqOuc&originHeight=1694&originWidth=3248&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=)

      Container Network
    

---

## Cilium: eBPF & XDP based CNI plugin

![](https://gw.alipayobjects.com/zos/antfincdn/iSIr4xVnkO/73cddcf9-6e5b-4a3f-8fa9-3d8e65b8f056.png#crop=0&crop=0&crop=1&crop=1&id=abFHP&originHeight=912&originWidth=1600&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=)

---

## 总结

- 勇于尝试新 kernel/runtime 和它们的新 feature .
- 工具可以快速验证思路, 过度依赖工具可能导致一叶障目不见泰山, **核心还是建立对系统的理解**.

![](https://gw.alipayobjects.com/zos/antfincdn/zHvsBUAZw3/f52a93d6-2263-4a2d-bd63-059266789f24.png#crop=0&crop=0&crop=1&crop=1&id=ZEv9O&originHeight=310&originWidth=325&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=)![](https://gw.alipayobjects.com/zos/antfincdn/HFPHA448hX/85db3710-1a5e-426e-96db-91c514a19cfc.png#crop=0&crop=0&crop=1&crop=1&id=UjanH&originHeight=324&originWidth=300&originalType=binary&ratio=1&rotation=0&showTitle=false&status=done&style=none&title=)

---

## Reference

-  1. [Probing the JVM with BPF/BCC](https://web.archive.org/web/20161006014657/http://blogs.microsoft.co.il/sasha/2016/03/31/probing-the-jvm-with-bpfbcc/)
-  2. [Debugging Java Native Memory Leaks](https://www.evanjones.ca/java-native-leak-bug.html)
-  3. [Goldshtein - Profiling JVM Applications in Production](https://www.usenix.org/sites/default/files/conference/protected-files/srecon18americas_slides_goldshtein.pdf)
-  4. [Debating the value of XDP](https://lwn.net/Articles/708087/)
-  5. [OSDI 2020 Summary](https://yuque.antfin.com/docs/share/ed2a2941-b51a-497f-b9a1-f393002d0473?#MevjG)
-  6. [hXDP: Efficient Software Packet Processing on FPGA NICs](https://www.usenix.org/conference/osdi20/presentation/brunella)
-  7. [XDP - challenges and future work](http://vger.kernel.org/lpc_net2018_talks/presentation-lpc2018-xdp-future.pdf)
-  8. [A practical introduction to XDP](https://www.linuxplumbersconf.org/event/2/contributions/71/attachments/17/9/presentation-lpc2018-xdp-tutorial.pdf)
-  9. [BPF and XDP Reference Guide — Cilium 1.9.0 documentation](https://docs.cilium.io/en/v1.9/bpf/)
-  10. [native memory leak](https://www.evanjones.ca/java-native-leak-bug.html)
-  11. [epoll native memory leak](https://github.com/netty/netty/pull/3844)
-  12. [JDK-8164293:HotSpot leaking memory](https://bugs.java.com/bugdatabase/view_bug.do?bug_id=JDK-8164293)
-  13. [借HSDB来探索HotSpot VM的运行时数据](https://www.iteye.com/blog/rednaxelafx-1847971)
-  14. [JDK-8158050](https://bugs.openjdk.java.net/browse/JDK-8158050)
-  15. [JVM团队-JFR使用帮助](https://yuque.antfin-inc.com/aone355606/gfqllg/xgllfm)
-  16. [JDK Mission Control Tutorial](https://yuque.antfin.com/office/lark/0/2020/pdf/122844/1606645147060-bef1c539-8c2a-4b7e-af40-4a8a5b8cc316.pdf?from=https%3A%2F%2Fyuque.antfin.com%2Fgnu.hl%2Fgnu%2Fxpdq41)
-  17. [Continuous Production Profiling and Diagnostics](http://hirt.se/blog/)
-  18. [Oracle Java Mission Control: The Ultimate Guide](https://www.javacodegeeks.com/2015/03/oracle-java-mission-control-the-ultimate-guide.html)
-  19. [perf one-liners](http://www.brendangregg.com/perf.html#OneLiners)
-  20. [Off-CPU Analysis](http://www.brendangregg.com/blog/2015-02-26/linux-perf-off-cpu-flame-graph.html)
-  21. [Bredan Gregg's perf examples](http://www.brendangregg.com/perf.html#JIT_Symbols)
-  22. [k{,ret}probes](https://www.kernel.org/doc/Documentation/kprobes.txt)
-  23. [u{,ret}probes](https://lwn.net/Articles/499190/)
-  24. [Kernel tracepoints](https://static.lwn.net/kerneldoc/trace/tracepoints.html)
-  25. [USDT](https://lwn.net/Articles/753601/)
-  26. [bpftrace Reference Guide](https://github.com/iovisor/bpftrace/blob/master/docs/reference_guide.md#bpftrace-reference-guide)
-  27. [Use eBPF to debug Hotspot JVM](https://github.com/AdoptOpenJDK/openjdk-build/issues/1173)
-  28. [Enable USDT probes for eBPF tracing on Linux #1173](https://github.com/AdoptOpenJDK/openjdk-build/issues/1173)
-  29. [Probing the JVM with BPF/BCC](https://web.archive.org/web/20161006014657/http://blogs.microsoft.co.il/sasha/2016/03/31/probing-the-jvm-with-bpfbcc/)
-  30. [Debugging Java Native Memory Leaks](https://www.evanjones.ca/java-native-leak-bug.html)
-  31. [Goldshtein - Profiling JVM Applications in Production](https://www.usenix.org/sites/default/files/conference/protected-files/srecon18americas_slides_goldshtein.pdf)
-  32. [Debating the value of XDP](https://lwn.net/Articles/708087/)
-  33. [OSDI 2020 Summary](https://yuque.antfin.com/docs/share/ed2a2941-b51a-497f-b9a1-f393002d0473?#MevjG)
-  34. [hXDP: Efficient Software Packet Processing on FPGA NICs](https://www.usenix.org/conference/osdi20/presentation/brunella)
-  35. [XDP - challenges and future work](http://vger.kernel.org/lpc_net2018_talks/presentation-lpc2018-xdp-future.pdf)
-  36. [A practical introduction to XDP](https://www.linuxplumbersconf.org/event/2/contributions/71/attachments/17/9/presentation-lpc2018-xdp-tutorial.pdf)
-  37. [BPF and XDP Reference Guide — Cilium 1.9.0 documentation](https://docs.cilium.io/en/v1.9/bpf/)

---

# Tribute To

- [Brendan Gregg](http://brendangregg.com/)
- [Sasha Goldshtein](https://github.com/goldshtn)
- [Julia Evans](https://jvns.ca/)
- [Rednaxelafx](https://www.iteye.com/blog/user/rednaxelafx)