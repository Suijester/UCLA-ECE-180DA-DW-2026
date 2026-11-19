"""Cocotb tests for combinational load_result.sv.

Run with the accompanying Makefile. Assumes RV32 and
MEM_BYTE=0, MEM_HALF=1, MEM_WORD=2; update enum values if needed.
"""
import cocotb
from cocotb.triggers import Timer

MEM_BYTE = 0
MEM_HALF = 1
MEM_WORD = 2
MASK32 = 0xFFFFFFFF


async def settle():
    await Timer(1, unit="ns")


def value(signal):
    return int(signal.value)


async def drive(dut, *, data=0, size=MEM_WORD, offset=0,
                unsigned=0, valid=1, ready=1, tag=3):
    dut.lq_out.value = data
    dut.load_out_mem_size.value = size
    dut.load_out_byte_offset.value = offset
    dut.load_out_unsigned.value = unsigned
    dut.load_out_valid.value = valid
    dut.load_data_ready.value = ready
    dut.load_out_rob_tag.value = tag
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


@cocotb.test()
async def test_load_variants(dut):
    """LB/LBU/LH/LHU/LW, including negative sign extension."""
    cases = [
        (MEM_BYTE, 2, 0, 0xFFFFFFBB),  # LB offset 2
        (MEM_BYTE, 2, 1, 0x000000BB),  # LBU offset 2
        (MEM_HALF, 2, 0, 0xFFFFAABB),  # LH offset 2
        (MEM_HALF, 2, 1, 0x0000AABB),  # LHU offset 2
        (MEM_WORD, 0, 0, 0xAABBCCDD),  # LW
    ]
    for size, offset, unsigned, expected in cases:
        await drive(dut, data=0xAABBCCDD, size=size,
                    offset=offset, unsigned=unsigned)
        assert value(dut.load_data) == expected, (
            f"size={size} offset={offset} unsigned={unsigned}: "
            f"got {value(dut.load_data):08X}, expected {expected:08X}"
        )


@cocotb.test()
async def test_all_byte_offsets(dut):
    """Check all four byte lanes for signed and unsigned loads."""
    words = [0x807F01FF, 0xAABBCCDD, 0x00010203, 0xFFFFFFFF]
    for word in words:
        for offset in range(4):
            for unsigned in (0, 1):
                await drive(dut, data=word, size=MEM_BYTE,
                            offset=offset, unsigned=unsigned)
                expected = expected_result(word, MEM_BYTE, offset, unsigned)
                assert value(dut.load_data) == expected, (
                    f"byte word={word:08X}, offset={offset}, unsigned={unsigned}"
                )


@cocotb.test()
async def test_halfword_offsets(dut):
    """Aligned halfwords at offsets 0 and 2."""
    for word in (0x80017FFF, 0x7FFF8000, 0xAABBCCDD, 0):
        for offset in (0, 2):
            for unsigned in (0, 1):
                await drive(dut, data=word, size=MEM_HALF,
                            offset=offset, unsigned=unsigned)
                expected = expected_result(word, MEM_HALF, offset, unsigned)
                assert value(dut.load_data) == expected, (
                    f"halfword word={word:08X}, offset={offset}, unsigned={unsigned}"
                )


@cocotb.test()
async def test_ready_valid_and_tag(dut):
    """Combinational pass-through and backpressure behavior."""
    for valid in (0, 1):
        for ready in (0, 1):
            await drive(dut, data=0x12345678, valid=valid,
                        ready=ready, tag=11)
            assert value(dut.load_data_valid) == valid
            assert value(dut.load_out_ready) == ready
            assert value(dut.load_data_rob_tag) == 11
            assert value(dut.load_data) == 0x12345678

    # Change ROB tag and data while downstream is stalled.
    # This module is combinational: the upstream LQ must hold them stable.
    await drive(dut, data=0xDEADBEEF, ready=0, tag=7)
    assert value(dut.load_out_ready) == 0
    assert value(dut.load_data_valid) == 1
    assert value(dut.load_data_rob_tag) == 7
    assert value(dut.load_data) == 0xDEADBEEF


@cocotb.test()
async def test_default_size(dut):
    """Invalid size encoding should produce zero."""
    await drive(dut, data=0xFFFFFFFF, size=3)
    assert value(dut.load_data) == 0
