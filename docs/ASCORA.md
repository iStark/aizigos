# Ascora in AIZigOS

The shell already answers questions in Russian and English. It does so with a
phrase table, and it says so out loud when it fails. This document is about
replacing that table with the model, and about what stands between here and
there.

## What the model is

Ascora Nano R1, from `E:\Ascora\fullmodel\ascrora-v7`:

| | |
|---|---|
| Parameters | ~83M, tied embeddings |
| Layers | 16 |
| Hidden size | 640 |
| Attention | 8 query heads, 4 KV heads (GQA), head dim 80 |
| Positions | RoPE |
| Norm | RMSNorm, pre-norm |
| FFN | SwiGLU, intermediate 1728 |
| Context | 4096 tokens |
| Tokenizer | SentencePiece BPE, 16k |
| Checkpoint | `ascora00021.pt`, 270 MB |

It already has the vocabulary for this job: `<|system|>`, `<|user|>`,
`<|assistant|>` roles and a `<cmd>` token, which is exactly the shape the
kernel needs — a sentence in, a command out.

## The seam

`kernel/agent.zig` defines `Intent`. Everything the shell can do is one of
those, and `perform` is the only thing that acts. The model's job is to turn a
sentence into an `Intent`; the kernel's job stays what it is: check the
capability, do the work, write the audit record.

That order is not a style choice. A model that could act directly would be a
model that could bypass FR-2.1, and the whole point of the capability system is
that nothing — including the thing that sounds most confident — gets to skip
the check. The model proposes; the kernel disposes.

## What is missing, in order

**1. The weights, in a format the kernel can read.** A PyTorch checkpoint is a
zip of pickled tensors; the kernel is not going to unpickle anything. A script
on the host exports the tensors into one flat file with a small header: shapes,
offsets, dtype. fp32 is 332 MB, fp16 is 166 MB, int8 with per-channel scales is
about 85 MB. int8 is the one that fits comfortably in a virtual machine and
needs no floating point at all in the hot loop.

**2. A way to get the file onto the machine.** `tools/mkimage.zig` already
builds a FAT32 volume and writes a file into it, so the build can put the
weights on the ESP next to the loader. What is missing is the other half: a
FAT32 *reader* in the kernel. That is a day's work and the symmetric twin of
code that already exists — and it is the first piece of section 4.3 as well.

**3. Arithmetic.** Every target currently builds with floating point disabled:
the kernel saves no FP state on a context switch, so it may not use FP
registers. Two ways out, and they are not exclusive:

* int8 weights with int32 accumulation — no FP in the hot loop, and the
  quantisation scales can be applied in fixed point;
* enable SSE2 on the UEFI target and save the FP state in `Context`, which
  costs 512 bytes per thread with FXSAVE.

**4. The inference engine.** RMSNorm, RoPE, grouped-query attention with a KV
cache, SwiGLU, a sampler. In Zig, without a tensor framework, this is on the
order of two thousand lines — large, but ordinary code with no surprises, and
testable on the host against reference outputs from the PyTorch model.

**5. The tokenizer.** SentencePiece BPE with a 16k vocabulary: load
`ascora.vocab`, implement the merge loop, handle the special tokens. A few
hundred lines, testable against the Python tokenizer's output.

**6. Speed, honestly.** 83M parameters at int8 is roughly 83 MB of weight reads
per token. Under QEMU without SIMD that is seconds per token; on real hardware
with AVX2 it is fractions of a second. The interface has to be built for a
model that thinks visibly — streaming tokens into the terminal window as they
arrive, not blocking the shell until a sentence is finished. The scheduler
already supports that: inference belongs in a `background` thread that yields,
so the desktop stays responsive and a flat battery pauses the model rather than
the machine.

## What runs today

The phrase table in `kernel/agent.zig`: about twenty stems per language mapped
onto the intents above, with numbers and addresses pulled out of the sentence.
It answers in the language it was asked in, and when it does not understand it
says that it is a table rather than guessing.

```
aizig> сколько свободной памяти
свободно памяти: 376 МиБ

aizig> выдай агенту доступ на 7 минут
выдан токен: 5
он живёт 7 минут

aizig> напиши стихотворение
Не понял. Пока это таблица фраз, а не модель.
```

Everything those sentences do goes through the same capability checks and lands
in the same audit log as the typed commands. When Ascora replaces the
recogniser, that stays true — which is the reason to build this half first.
