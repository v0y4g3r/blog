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



## 合并策略

- 分级合并（Leveling Merge Policy）
  - 每一级都有且只有一个文件
- 分层合并 (Tiering Merge Policy)
  - 每一级有多个小文件，每个小文件中的 key 不重叠（LevelDB 和 RocksDB采用，尽管他们称自己为 leveling merge）

- 合并时间：定时合并、达到阈值合并。

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

- [理论结合实践详解 lsm 树存储引擎（bitcask、moss、leveldb 等）](https://www.youtube.com/watch?v=adamqSuHHck&ab_channel=TalkGo)


