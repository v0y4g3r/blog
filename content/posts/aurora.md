---
title: "Notes on Amazon Aurora"
date: 2023-05-28T17:43:25+08:00
draft: false
toc: true
math: true
images:
tags: 
  - Database
---

# Notes on Amazon Aurora

## Amazon Aurora
- SQL、事务处理等等完全基于 MySQL
- 将 page 这个层面的 IO 委托给基于 quorum-replication 的存储系统
- 基于 redo log 做数据复制，避免了 MySQL 正常复制场景下的大量 IO
- 支持 AZ+1 的容灾，简化了运维

## The log is the database

- MySQL 的 IO 太多导致在云场景下写放大严重（3.1）
   - page 需要写到 heap file 里面
   - redo log 需要写到 WAL 里面
   - 真实世界的 HA 集群还需要一些其他的数据同步，比如 binlog 等等
   - 最糟糕的是这些写入都是同步的（图中的 1,2,3,4,5），可能导致延迟的成倍放大

![](https://assets.huanglei.co/20230528175431.png)


- Aurora 的解决方法：the log is the database
   - 只有 redo log 是写入到是跨 AZ 复制的 storage 层，因为将 redo log 回放一遍就可以得到 page 的最终状态
   - DB 不直接写入 page 到 storage，storage 层将 log 物化为 page，on demand
   - 所谓的 page，只是 log application 的一个缓存


![](https://assets.huanglei.co/20230528175539.png)


## Quorums

- Read-Write conflicts
   - Qr 和 Qw 一定会有交叉，一旦写入Qw，一定能够读到最新写入的数据
   - Partial writes	
      - 假设一个 write 只写了 1 个节点就宕机了，那么这个写入实际上并未 commit
      - reader 无论如何也是无法读取满足 Qr 的数据的
- Write-Write conflicts
   - 对同一个状态的更改可能同时发生，在读取的时候 reader 可能从 Qr 中读取到不同的数据。这个时候需要在写入的时候加上版本号之类的机制判断
      - 要么客户端从 Qr 中获取最高的版本，然后只能不停重试直到能够把这个版本的数据所依赖的副本数量补齐为止
      - 或者写入者维护一个最高的已确认版本号，读取的时候根据这个版本号来读取（适用于单 writer）
      - 或者 writer 每次写绝对多数（即 Qw > n/2）。
- Quorum 和 Chain-replication
   - 对 grey failure 节点处理更好
      - 不需要检测故障或者等待超时
      - 在跨 AZ 复制或者长链路复制场景下时延更优
   - 可以灵活调整 Qr 和 Qw 从而获得不同的写入、读取性能
   - 但是：
      - Qw 之外的节点需要同步最新的状态
      - 依赖 version number，因此更适合单 writer 场景（比如 WAL）

### 为什么 Aurora 需要 6 副本?

- 因为 Aurora 设计目标需要容忍 AZ+1 failure
- 节点 crash 是非常频繁的，比如运维操作。而一旦 3AZ 容灾模式下出现 AZ failure 的同时出现了机器下线或者 crash，那么就会立刻导致数据损坏。单个 AZ 挂掉再加一个节点挂掉的情况也能保证数据不丢失

![](https://assets.huanglei.co/20230528175559.png)


- 上图是 3AZ （3 副本）情况，AZ 3 failure 之后，其他任何一个 AZ 只要一个节点出问题就会导致数据损坏。
- 下图是 3AZ（6 副本），在 quroum 只剩 4/6 的时候（比如单 AZ failure），仍然可以支持写操作；在 quorum 只剩 3/6（单 AZ failure+单节点 crash ）的时候仍然可以支持读操作，并且可以依靠这个读操作快速恢复出一个副本从而继续提供写操作。这样就大大提升了系统的容灾能力。
- 为什么 6/4/3 可以容忍 AZ+1 失效？
   - 当单个 AZ 失效的时候，quorum 还剩 4 个节点，这个时候仍然可，以接受 Qw=4 的写入
   - 如果这个时候又出现了单机 crash，仍然可以接受 Qr=3 的读请求，并且可以用读快速恢复出一个新的副本从而满足 Qw=4
   - 即使出现了单个 AZ 长时间的不可用，也可以降级为 4/3/2 的 quorum，使得即使 4 个节点也能接受写入请求
## Storage service 设计
核心目标：降低写入的延迟

![](https://assets.huanglei.co/20230528175616.png)

1. 接受主节点（primary instance）写入请求并且加入到内存队列中
2. 持久化到磁盘并且向主节点返回 ACK
3. 将 log records 排序，找到自己所缺少的 log
4. 通过 gossip 协议向其他 storage node 请求缺少的 log 并补齐
5. 将连续的 log records apply 成为 data pages
6. 持久化到 S3 从而实现 time travel（基于时间点的快照）
7. 定期 GC
8. 定期校验 CRC
> 在上面的流程中所有的步骤都是异步的，而且只要 1 和 2 会影响写入的延迟



#### 存储服务详细设计

![](https://assets.huanglei.co/20230528175647.png)

Aurora 存储结构

- Protection group & segment
   - 一个 database 的数据分布在不同的 PG 上
   - PG 是逻辑上的一组 segments 组成的，segment 大小为 10G
- SCL(Segment Complete LSN) (at storage server, per segment)
   - Segment 上最大的连续 LSN，可以认为是存储节点的 last log indexdra
      - 注意这里的“连续”，并不代表是递增的连续。因为 LSN 本质上是 page 的偏移，不可能做到递增的连续。Aurora 这里的“连续”是通过 back link 机制实现的，即链表概念里面的连续：每个 log entry 都有一个指向前一个 entry 的连接。
      - 原文："SCL is the inclusive upper bound on log records **continuously linked through the segment chain** without gaps", "Note that each segment of each PG only sees a subset of log records in the volume that affect the pages residing on that segment. **Each log record contains a backlink that identifies the previous log record for that PG**. These backlinks can be used to track the point of completeness of the log records that have reached each segment to establish a Segment Complete LSN (SCL) that identifies the greatest LSN below which all log records of the PG have been received. "
   - SCL 之前（包含 SCL）的 log 都已经在当前存储节点上了
   - 存储节点在向 DB 实例返回写入 ACK 的同时会带上 SCL，这样 DB 节点就能知道所有存储节点最新的 SCL
- PGCL(Protection Group Complete LSN) (at database instance, per PG)
   - PGCL 用来标识，PG 内部在此之前所有的写入已经持久化（到达 Qw ）了。
   - DB 实例在收到存储节点的 ACK 的时候，就能根据所有 6 副本当前的 SCL 判断自己的 PGCL

![](https://assets.huanglei.co/20230528175706.png)

   - 如上图 PG1 和 PG2 的 PGCL 分别为 103 和 104
   - VCL 为 104，因为 104 之前的所有 log 都已经满足 Qw
- VCL(Volume Complete LSN)	 (at database instance, per volume)
   - The database instance also locally advances a Volume Complete LSN (VCL) once there are no pending writes preventing PGCL from advancing for one of its protection groups.
   - DB 实例必须确保整个 log chain 的完整性。小于等于 VCL 的事务都已经确认提交，在 recover 的时候一定能够从存储节点恢复出来。
      - VCL 和 SCL 有什么区别？SCL 是针对 segment 来说的，用处是 storage 节点之间互相补齐副本数量；VCL 是针对 DB 实例的整个 log chain 来说的
   - 在 recover 的时候，LSN 大于 VCL 的数据必须被删除
   - 当事务的 commit redo log 的 LSN 小于等于 VCL 的时候，这个事务就可以被认为是 commit 了
      - Aurora must wait to acknowledge commits until it is able to  advance VCL beyond the requesting SCN. (2.3)
- VDL(Volume Durable LSN)
   - 小于 VCL 的最后一个 MTR 的 LSN
   - 用于规避 reader 看到不完整的 MTR，从而确保 MTR 的原子性

![](https://assets.huanglei.co/20230528175721.png)

{{% img-title %}} 从完整的 Volume 例子来看，各个 segment、PG 上的 SCL、PGCL 和 VCL {{% /img-title %}} 

#### 故障恢复（Crash recovery）
在恢复时，DB 实例需要根据存储节点的 SCL 恢复出来 PGCL 和 VCL

![](https://assets.huanglei.co/20230528175743.png)
{{% img-title %}}故障恢复时进行日志截断（log truncation）{{% /img-title %}} 




## Read replica
通过只读副本提高读性能。Aurora 的只读副本与主副本连接相同的 storage volume，并且只读副本从主副本接收 redo log 流用于更新 DB instance 内存的 buffer cache。如果 redo log 流包含了不在当前只读副本内存中的 data page，只读副本是直接将这些 log 丢弃的，因为这些 page 一定可以从 storage volume 中读出来。

## Reference

- [Amazon Aurora: Design Considerations for High Throughput Cloud-Native Relational Database](https://link.zhihu.com/?target=https%3A//web.stanford.edu/class/cs245/readings/aurora.pdf)
- [Amazon Aurora: On Avoiding Distributed Consensus for I/Os, Commits, and Membership Changes](https://link.zhihu.com/?target=https%3A//pages.cs.wisc.edu/~yxy/cs764-f20/papers/aurora-sigmod-18.pdf)
- [Amazon Aurora FAQ - nil.lcs.mit.edu](http://nil.lcs.mit.edu/6.824/2020/papers/aurora-faq.txt)
- [Lecture 10: Database logging, quorums, Amazon Aurora -  pdos.csail.mit.edu](https://pdos.csail.mit.edu/6.824/notes/l-aurora.txt)
- [从分布式Distributed、日志Log、一致性Consistency分析AWS Aurora for MySQL](https://zhuanlan.zhihu.com/p/549700484)
- [01-AWS Aurora](https://zhuanlan.zhihu.com/p/391235701)
- [Aurora读写细节分析](https://zhuanlan.zhihu.com/p/508928878)
