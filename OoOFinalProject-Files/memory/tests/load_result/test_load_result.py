
"""Cocotb tests for load_result with load/store completion FIFOs.

TOPLEVEL: load_result_tb_wrapper

Assumptions:
- RV32
- MEM_BYTE=0, MEM_HALF=1, MEM_WORD=2
- Separate depth-4 load/store completion FIFOs
- One completion emitted per cycle
- Ready/valid interfaces
"""

import cocotb
from cocotb.triggers import Timer

MEM_BYTE = 0
MEM_HALF = 1
MEM_WORD = 2
MASK32 = 0xFFFFFFFF
FIFO_DEPTH = 4


def value(signal):
    return int(signal.value)


async def settle():
    await Timer(1, unit="ns")


async def tick(dut):
    """Advance one clock edge, then settle."""
    dut.clk.value = 0
    await settle()
    dut.clk.value = 1
    await settle()
    dut.clk.value = 0
    await settle()


async def reset(dut):
    dut.clk.value = 0
    dut.rst_n.value = 0

    dut.lq_out.value = 0
    dut.load_out_valid.value = 0
    dut.load_out_rob_tag.value = 0
    dut.load_out_mem_size.value = MEM_WORD
    dut.load_out_byte_offset.value = 0
    dut.load_out_unsigned.value = 0
    dut.load_out_writeback_pdst.value = 0
    dut.load_out_under_unresolved_branch.value = 0

    dut.store_out_valid.value = 0
    dut.store_out_rob_tag.value = 0
    dut.store_out_comp_under_branch.value = 0

    dut.result_ready.value = 0

    await tick(dut)
    await tick(dut)
    dut.rst_n.value = 1
    await settle()


def expected_result(word, size, offset, unsigned):
    shifted = (word & MASK32) >> (8 * offset)

    if size == MEM_BYTE:
        width = 8
    elif size == MEM_HALF:
        width = 16
    elif size == MEM_WORD:
        return shifted & MASK32
    else:
        return 0

    bits = shifted & ((1 << width) - 1)

    if not unsigned and bits & (1 << (width - 1)):
        bits |= MASK32 ^ ((1 << width) - 1)

    return bits & MASK32


async def enqueue_load(
    dut, *, data, size=MEM_WORD, offset=0,
    unsigned=0, tag=3, pdst=5, branch=0
):
    dut.lq_out.value = data
    dut.load_out_mem_size.value = size
    dut.load_out_byte_offset.value = offset
    dut.load_out_unsigned.value = unsigned
    dut.load_out_rob_tag.value = tag
    dut.load_out_writeback_pdst.value = pdst
    dut.load_out_under_unresolved_branch.value = branch
    dut.load_out_valid.value = 1

    await settle()
    assert value(dut.load_out_ready) == 1, "Load FIFO not ready"

    await tick(dut)
    dut.load_out_valid.value = 0
    await settle()


async def enqueue_store(dut, *, tag=7, branch=0):
    dut.store_out_valid.value = 1
    dut.store_out_rob_tag.value = tag
    dut.store_out_comp_under_branch.value = branch

    await settle()
    assert value(dut.store_out_ready) == 1, "Store FIFO not ready"

    await tick(dut)
    dut.store_out_valid.value = 0
    await settle()


def check_completion(
    dut, *, tag, writeback, data=0, pdst=0, branch=0
):
    assert value(dut.result_valid) == 1, "Expected completion"
    assert value(dut.result_rob_tag) == tag
    assert value(dut.result_writeback_valid) == writeback
    assert value(dut.result_writeback_pdst) == pdst
    assert value(dut.result_value) == data
    assert value(dut.result_under_unresolved_branch) == branch


@cocotb.test()
async def test_load_variants(dut):
    """LB, LBU, LH, LHU, LW through the completion FIFO."""
    await reset(dut)

    cases = [
        (MEM_BYTE, 2, 0, 0xFFFFFFBB),
        (MEM_BYTE, 2, 1, 0x000000BB),
        (MEM_HALF, 2, 0, 0xFFFFAABB),
        (MEM_HALF, 2, 1, 0x0000AABB),
        (MEM_WORD, 0, 0, 0xAABBCCDD),
    ]

    for i, (size, offset, unsigned, expected) in enumerate(cases):
        await enqueue_load(
            dut,
            data=0xAABBCCDD,
            size=size,
            offset=offset,
            unsigned=unsigned,
            tag=i + 1,
            pdst=i + 10,
        )

        check_completion(
            dut,
            tag=i + 1,
            writeback=1,
            data=expected,
            pdst=i + 10,
        )

        dut.result_ready.value = 1
        await tick(dut)
        dut.result_ready.value = 0
        await settle()

        assert value(dut.result_valid) == 0


@cocotb.test()
async def test_all_byte_offsets(dut):
    """All byte lanes, signed and unsigned."""
    await reset(dut)

    words = [0x807F01FF, 0xAABBCCDD, 0x00010203, 0xFFFFFFFF]

    for word in words:
        for offset in range(4):
            for unsigned in (0, 1):
                await enqueue_load(
                    dut,
                    data=word,
                    size=MEM_BYTE,
                    offset=offset,
                    unsigned=unsigned,
                )

                expected = expected_result(
                    word, MEM_BYTE, offset, unsigned
                )

                check_completion(
                    dut,
                    tag=3,
                    writeback=1,
                    data=expected,
                    pdst=5,
                )

                dut.result_ready.value = 1
                await tick(dut)
                dut.result_ready.value = 0
                await settle()


@cocotb.test()
async def test_halfword_offsets(dut):
    """Aligned halfwords at offsets 0 and 2."""
    await reset(dut)

    for word in (0x80017FFF, 0x7FFF8000, 0xAABBCCDD, 0):
        for offset in (0, 2):
            for unsigned in (0, 1):
                await enqueue_load(
                    dut,
                    data=word,
                    size=MEM_HALF,
                    offset=offset,
                    unsigned=unsigned,
                )

                check_completion(
                    dut,
                    tag=3,
                    writeback=1,
                    data=expected_result(
                        word, MEM_HALF, offset, unsigned
                    ),
                    pdst=5,
                )

                dut.result_ready.value = 1
                await tick(dut)
                dut.result_ready.value = 0
                await settle()


@cocotb.test()
async def test_load_metadata(dut):
    """Physical destination and branch flag are preserved."""
    await reset(dut)

    await enqueue_load(
        dut,
        data=0x12345678,
        tag=9,
        pdst=17,
        branch=1,
    )

    check_completion(
        dut,
        tag=9,
        writeback=1,
        data=0x12345678,
        pdst=17,
        branch=1,
    )


@cocotb.test()
async def test_store_completion(dut):
    """Stores complete to ROB but do not write back a register."""
    await reset(dut)

    await enqueue_store(dut, tag=11, branch=1)

    check_completion(
        dut,
        tag=11,
        writeback=0,
        data=0,
        pdst=0,
        branch=1,
    )


@cocotb.test()
async def test_load_fifo_backpressure(dut):
    """FIFO fills while downstream is stalled."""
    await reset(dut)

    dut.result_ready.value = 0

    for i in range(FIFO_DEPTH):
        await enqueue_load(
            dut,
            data=0x100 + i,
            tag=i + 1,
            pdst=i + 5,
        )

    assert value(dut.load_out_ready) == 0, (
        "Load FIFO should be full"
    )

    # Head must remain stable while downstream is stalled.
    for _ in range(3):
        check_completion(
            dut,
            tag=1,
            writeback=1,
            data=0x100,
            pdst=5,
        )
        await tick(dut)

    # Drain all entries in order.
    dut.result_ready.value = 1

    for i in range(FIFO_DEPTH):
        await settle()
        check_completion(
            dut,
            tag=i + 1,
            writeback=1,
            data=0x100 + i,
            pdst=i + 5,
        )
        await tick(dut)

    assert value(dut.result_valid) == 0


@cocotb.test()
async def test_store_fifo_backpressure(dut):
    """Store FIFO independently buffers four completions."""
    await reset(dut)

    for i in range(FIFO_DEPTH):
        await enqueue_store(dut, tag=i + 1)

    assert value(dut.store_out_ready) == 0

    dut.result_ready.value = 1

    for i in range(FIFO_DEPTH):
        await settle()
        check_completion(
            dut,
            tag=i + 1,
            writeback=0,
            data=0,
            pdst=0,
        )
        await tick(dut)

    assert value(dut.result_valid) == 0


@cocotb.test()
async def test_round_robin_arbitration(dut):
    """Both queues eventually receive service."""
    await reset(dut)

    for i in range(3):
        await enqueue_load(
            dut,
            data=0xA0 + i,
            tag=i + 1,
            pdst=i + 5,
        )
        await enqueue_store(dut, tag=i + 11)

    dut.result_ready.value = 1

    observed = []

    for _ in range(6):
        await settle()
        assert value(dut.result_valid) == 1

        observed.append((
            value(dut.result_rob_tag),
            value(dut.result_writeback_valid),
        ))

        await tick(dut)

    assert value(dut.result_valid) == 0

    load_tags = [tag for tag, wb in observed if wb]
    store_tags = [tag for tag, wb in observed if not wb]

    assert load_tags == [1, 2, 3], load_tags
    assert store_tags == [11, 12, 13], store_tags

    # Both requesters should alternate while both are nonempty.
    for i in range(1, len(observed)):
        assert observed[i][1] != observed[i - 1][1], (
            f"Arbiter did not alternate: {observed}"
        )


@cocotb.test()
async def test_arbitration_stall_stability(dut):
    """Selected completion must not change during a stall."""
    await reset(dut)

    await enqueue_load(dut, data=0xDEADBEEF, tag=4, pdst=8)
    await enqueue_store(dut, tag=9)

    await settle()

    first = (
        value(dut.result_rob_tag),
        value(dut.result_writeback_valid),
        value(dut.result_value),
    )

    for _ in range(5):
        assert value(dut.result_valid) == 1

        current = (
            value(dut.result_rob_tag),
            value(dut.result_writeback_valid),
            value(dut.result_value),
        )

        assert current == first, (
            "Completion changed while result_ready=0"
        )

        await tick(dut)

    dut.result_ready.value = 1
    await tick(dut)

    assert value(dut.result_valid) == 1
    assert value(dut.result_rob_tag) != first[0]

    await tick(dut)
    assert value(dut.result_valid) == 0


@cocotb.test()
async def test_invalid_size(dut):
    """Invalid size encoding produces zero data."""
    await reset(dut)

    await enqueue_load(
        dut,
        data=0xFFFFFFFF,
        size=3,
        tag=6,
        pdst=12,
    )

    check_completion(
        dut,
        tag=6,
        writeback=1,
        data=0,
        pdst=12,
    )
