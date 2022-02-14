---
title: "Paxos Made Simple 笔记 (WIP)"
date: 2021-06-14T11:24:18+08:00
draft: false
toc: false
images:
math: true
tags: 
  - Consensus
  - Paxos
---

# 关于 P2c
P2c 是 P2b 的充分不必要条件，why？

> - P2b: If a proposal with value v is chosen, then every higher-numbered proposal issued by any proposer has value `v`.
> - P2c: For any `v` and `n`, if a proposal with value `v` and number `n` is issued, then there is a set S consisting of a majority of acceptors such that either
>    - (a) no acceptor in S has accepted any proposal numbered less than `n`, or
>    - (b) `v` is the value of the highest-numbered proposal among all proposals numbered less than `n` accepted by the acceptors in S.


已知 proposal:`(m,v)`被选中，要满足任意 proposer 提出序号 n （n > m）的 proposal 的值都是 `v`，那么只要满足条件：<u> $ \forall i\in [m,\ n-1]$ ，有 proposal `i` 的值是 `v` 1</u>，那么根据数学归纳法，proposal `n`的值也必然是 `v`。

1: 是附加假设，我们需要根据这个附加假设去约束 proposer 的行为，从而使得 P2b 能够被满足。下面就需要解释这个附加假设对 proposer 的行为做出了什么样的约束。

由于 `(m,v)`已经被选中了，那就意味着存在一个 acceptor 的集合 C 满足任意 C 中的 acceptor 都 accept 了`(m,v)`，再加上我们需要让附加假设（满足 $i\in [m,\ n-1]$ ，有 proposal `i` 的值是 `v`）成立，
这就意味着所谓的 C-condition 2 ，对于 accept 了 `(m,v)` 的 acceptor 集合 C，满足：

- (1)  C 中的所有 acceptor 都 accept 了 $[m,\ n-1]$ 中的一个 proposal（因为至少有`m`已经被 C 中的所有 acceptor 给 accept 了）
- (2) $[m,\ n-1]$ 中所有的被任意 acceptor 所 accept 的 proposal 的值都是 `v`（注意，这里约束的对象从 proposer 变成了 acceptor，实际上 narrow down 了，因为是非拜占庭问题，所有被 acceptor 所 accept 的值都需要 proposer 提出）。



那么只要 proposer 满足 P2c，就能满足所谓的 C-condition，从而实现 P2c -> C-condidtion -> 附加假设 1-> P2b 的证明路径。
> 为什么 P2c 可以保证 C-condidition？
> P2c 约束了 proposer 每次提案之前先要知道 majority 的情况，由于`(m,v)`已经 chosen，因此符合 P2c 的 proposer 在提出 m+1 的时候，提案的值必然是 m（highest accepted proposal）的值 v，m+2、m+3 直到 n-1 都是这样，从而可以保证 C-condition 的 (2)，


因此 P2b 到 P2c 实际上是让约束逐步可实现化的 narrow down，因为让 proposer 去感知 acceptor 的状态是更容易实现的。

> Learning about proposals already accepted is easy enough; predicting future acceptances is hard. Instead of trying to predict the future, the proposer controls it by extracting a promise that there won’t be any such acceptances.
