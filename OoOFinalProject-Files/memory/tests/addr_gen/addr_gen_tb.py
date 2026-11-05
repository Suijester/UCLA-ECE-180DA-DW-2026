
import cocotb
from cocotb.triggers import Timer


# Update these values to match mem_size_e in rv32_ooo_pkg.sv
MEM_BYTE = 0
MEM_HALF = 1
MEM_WORD = 2

MASK32 = 0xFFFFFFFF


async def check_agu(
    dut,
    base,
    imm,
    size,
    data,
    expected_addr,
    expected_offset,
    expected_mask,
    expected_store_data,
    expected_misaligned,
):
    
    dut.source_1.value = base
    dut.source_2.value = data
    dut.immediate.value = imm & MASK32
    dut.access_size.value = size

    # Allow combinational logic to settle
    await Timer(1, unit="ns")

    assert int(dut.word_addr.value) == expected_addr, (
        f"word_addr: expected {expected_addr:#x}, "
        f"got {int(dut.word_addr.value):#x}"
    )

    assert int(dut.byte_offset.value) == expected_offset
    assert int(dut.bytes_accessed.value) == expected_mask
    assert int(dut.store_data.value) == expected_store_data
    assert int(dut.misaligned_access.value) == expected_misaligned


@cocotb.test()
async def test_byte_accesses(dut):
    """Byte loads/stores at all four offsets."""

    for offset in range(4):
        await check_agu(
            dut,
            base=0x1000,
            imm=offset,
            size=MEM_BYTE,
            data=0x123456AB,
            expected_addr=0x1000,
            expected_offset=offset,
            expected_mask=1 << offset,
            expected_store_data=0xABABABAB,
            expected_misaligned=0,
        )


@cocotb.test()
async def test_halfword_accesses(dut):
    """Halfword accesses: aligned and misaligned."""

    for offset in range(4):
        await check_agu(
            dut,
            base=0x2000,
            imm=offset,
            size=MEM_HALF,
            data=0x1234BEEF,
            expected_addr=0x2000,
            expected_offset=offset,
            expected_mask=0x3 if offset < 2 else 0xC,
            expected_store_data=0xBEEFBEEF,
            expected_misaligned=int(offset % 2 != 0),
        )


@cocotb.test()
async def test_word_accesses(dut):
    """Word accesses must be 4-byte aligned."""

    for offset in range(4):
        await check_agu(
            dut,
            base=0x3000,
            imm=offset,
            size=MEM_WORD,
            data=0xDEADBEEF,
            expected_addr=0x3000,
            expected_offset=offset,
            expected_mask=0xF,
            expected_store_data=0xDEADBEEF,
            expected_misaligned=int(offset != 0),
        )


@cocotb.test()
async def test_negative_immediate(dut):
    """Address generation with a negative immediate."""

    await check_agu(
        dut,
        base=0x1004,
        imm=-4,
        size=MEM_WORD,
        data=0xCAFEBABE,
        expected_addr=0x1000,
        expected_offset=0,
        expected_mask=0xF,
        expected_store_data=0xCAFEBABE,
        expected_misaligned=0,
    )


@cocotb.test()
async def test_address_wraparound(dut):
    """RV32 address arithmetic wraps at 32 bits."""

    await check_agu(
        dut,
        base=0xFFFFFFFC,
        imm=4,
        size=MEM_WORD,
        data=0x12345678,
        expected_addr=0,
        expected_offset=0,
        expected_mask=0xF,
        expected_store_data=0x12345678,
        expected_misaligned=0,
    )
