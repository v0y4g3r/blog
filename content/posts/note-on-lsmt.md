---
title: "LSM Tree 笔记"
date: 2022-02-10T22:34:39+08:00
draft: false
toc: false
images:
tags: 
  - Database
---

## 写入（Write path）

- 先从磁盘（HDD）写入的特性引入 append-only 的 WAL。

- 对于 KV 结构，如果写入是 append only的，那么就需要合并，不然读取性能太差。

- 单文件合并性能差，因此需要按阈值切分为多个小文件，通过归并排序的思路优化合并的效率。

- 多路归并要求每个文件有序，为了保证每个文件有序，就需要，数据写入的时候，不直接把 operation 直接写入到磁盘，而是先在内存缓存一段时间，并且在内存排好序，然后再一次把整个文件 flush 到磁盘。
  - 内存有序的数据结构：跳表、红黑树、B+ 树
  - buffer 在内存的数据丢了怎么办？先写 redo log



## 有序数据结构

![](https://gw.alipayobjects.com/zos/antfincdn/V8oKiYS5z/1639280343.png)

> [RocksDB 的数据结构比较](https://github.com/facebook/rocksdb/wiki/MemTable)：选择跳表的原因是跳表支持并发插入。



LSMT 的数据分类

- 内存数据：MemTable
- 磁盘数据：SSTable（Sorted Sequence Table）
- 日志：redo log



## 内存数据组织

内存的数据需要保证有序，同时支持高性能的插入和查找。

- ART：自适应基树（比如 Bitcask 采用）；
- SkipList：LevelDB、RocksDB 等。



## SSTable 文件格式

按 Block 进行存储，可以参考 LevelDB 和 RocksDB 的 SST 文件的格式。



## Compaction

- Leveling compaction
  - 当某个 level 出现一个新的 sorted run 的时候触发；
  - 每一级的文件只会组成一个 sorted run，也就是说不同文件的 key range 不会重叠；
  - 写放大较大，但查询性能好，适合写少读多的 workload。
- Tiering compaction
  - 当某个 level 的 size 达到阈值时触发；
  - 每一级可能存在多个 sorted run；
  - 读放大和空间放大小，但 compaction 开销大，适合读多写少的 workload。

> 对于 tiering 和 leveling 的比较，我们可以考虑一种极限情况：只有一个 level。此时 tiering 变成一个 append only 的 log，每次产生一个新的 SST 只会 append 到 SST file queue 末尾，这种情况下写性能较高因为 flush 不涉及到已有的 SST，而读取性能则较差，因为有可能需要遍历所有的 SST。而 leveling 要求一层内只有一个 sorted run，因此会变成一个 sorted array，每次 flush 都会导致现有的 SST 被完整重写以排序，因此写放大较大而读性能好。

- 事实上工业级的 LSMT 往往会采用混合策略，比如 [RocksDB 在 Level 0 使用 tiering compaction](https://github.com/facebook/rocksdb/blob/9502856edd77260bf8a12a66f2a232078ddb2d60/db/compaction/compaction_picker_level.cc#L483-L484) 以提高写性能而在其他 level 使用 leveling compaction 以提高查询性能。

## 读取（Read path）

核心原则：先热后冷读取最新的数据，一旦读取到就停止。

- 优先读取 MemTable，然后读取 SSTable

### 读取的优化

- 通过 BloomFilter 优化不存在的数据的判断 
- SSTable 分区
- 压缩

## LSMT 的问题

### 读放大

一次 key 的读取需要由新到旧依次读取，涉及到不止一次IO，在范围查询的时候尤其明显。

### 写放大

后台合并（compaction）导致一个文件可能需要被写入多次。

### 空间放大

Append-only 导致过期数据一致存在，直到被清理



## 总结

- 写放大：尽管 LSM Tree 通过顺序 IO 提供了更大的写入吞吐，但是写入放大的问题会争抢正常写入的磁盘带宽，从而降低性能和磁盘的使用寿命。
- 合并：后台的合并操作导致 write stall
- 新硬件：Remote compaction，Compaction offloading，AEP



索引存储

- 索引不存储
  - buntdb：每次重启重建
- 索引存储
  - 分离存储
    - Bitcask
    - MySQL MyISAM
  - 一起存储
    - BoltDB
    - MySQL Innodb
    - LevelDB (SStable)



# Reference

- [Dostoevsky: Better Space-Time Trade-Offs for LSM-Tree Based Key-Value Stores via Adaptive Removal of Superfluous Merging](https://dl.acm.org/doi/abs/10.1145/3183713.3196927)
- [深入探讨LSM Compaction机制](https://zhuanlan.zhihu.com/p/141186118)


