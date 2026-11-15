"""cocotb tests for store_forward.sv (purely combinational).

A store's data is copied into every byte lane (as address_gen produces it),
so a byte store of 0xAB is 0xABABABAB with one byte-enable bit set.
"""
import cocotb
from cocotb.triggers import Timer

SQ_SIZE = 8
CACHE = 0x44332211     # cache word used by every test: byte0=11 .. byte3=44


def replicate(value, size):
    if size == 1:
        return (value & 0xFF) * 0x01010101
    if size == 2:
        return (value & 0xFFFF) * 0x00010001
    return value & 0xFFFFFFFF


async def run(dut, stores, head, ld_tail, ld_addr, ld_bytes):
    """stores: {slot: (word_addr, bytes_en, data_replicated)}; returns fwd outputs."""
    valid = addr_flat = bytes_flat = data_flat = 0
    for slot, (addr, ben, data) in stores.items():
        valid |= 1 << slot
        addr_flat |= addr << (32 * slot)
        bytes_flat |= ben << (4 * slot)
        data_flat |= data << (32 * slot)
    dut.sq_valid.value = valid
    dut.sq_word_addr_flat.value = addr_flat
    dut.sq_bytes_accessed_flat.value = bytes_flat
    dut.sq_write_data_flat.value = data_flat
    dut.sq_head.value = head
    dut.ld_sq_tail.value = ld_tail
    dut.ld_word_addr.value = ld_addr
    dut.ld_bytes_accessed.value = ld_bytes
    dut.cache_read_data.value = CACHE
    await Timer(1, units="ns")
    return (int(dut.fwd_data.value), int(dut.fwd_bytes_from_store.value),
            int(dut.fwd_all_from_store.value))


@cocotb.test()
async def test_no_stores_uses_cache(dut):
    data, from_store, all_fwd = await run(dut, {}, 0, 0, 0x100, 0xF)
    assert data == CACHE
    assert from_store == 0
    assert all_fwd == 0


@cocotb.test()
async def test_full_word_forward(dut):
    stores = {0: (0x100, 0xF, 0xDEADBEEF)}
    data, from_store, all_fwd = await run(dut, stores, 0, 1, 0x100, 0xF)
    assert data == 0xDEADBEEF, f"got {data:#x}"
    assert from_store == 0xF
    assert all_fwd == 1


@cocotb.test()
async def test_partial_overlap_merges_with_cache(dut):
    """sb 0xAB to byte 1; lw of the word gets 0xAB in byte 1, cache elsewhere."""
    stores = {0: (0x100, 0b0010, replicate(0xAB, 1))}
    data, from_store, all_fwd = await run(dut, stores, 0, 1, 0x100, 0xF)
    assert data == 0x4433AB11, f"got {data:#x}"
    assert from_store == 0b0010
    assert all_fwd == 0


@cocotb.test()
async def test_youngest_older_store_wins(dut):
    """Two older stores write byte 0; the younger of the two wins."""
    stores = {0: (0x100, 0b0001, replicate(0x55, 1)),
              1: (0x100, 0b0001, replicate(0x66, 1))}
    data, from_store, _ = await run(dut, stores, 0, 2, 0x100, 0b0001)
    assert data & 0xFF == 0x66, f"got byte {data & 0xFF:#x}"
    assert from_store == 0b0001


@cocotb.test()
async def test_younger_store_ignored(dut):
    """A store allocated after the load (at or past ld_sq_tail) must not forward."""
    stores = {0: (0x100, 0b0001, replicate(0x55, 1)),
              1: (0x100, 0b0001, replicate(0x77, 1))}   # slot 1 is younger than the load
    data, _, _ = await run(dut, stores, 0, 1, 0x100, 0b0001)
    assert data & 0xFF == 0x55, f"got byte {data & 0xFF:#x}"


@cocotb.test()
async def test_different_word_ignored(dut):
    stores = {0: (0x104, 0xF, 0xCAFEF00D)}
    data, from_store, _ = await run(dut, stores, 0, 1, 0x100, 0xF)
    assert data == CACHE
    assert from_store == 0


@cocotb.test()
async def test_halfword_load_from_word_store(dut):
    stores = {0: (0x100, 0xF, 0xDEADBEEF)}
    data, from_store, all_fwd = await run(dut, stores, 0, 1, 0x100, 0b1100)
    assert (data >> 16) & 0xFFFF == 0xDEAD
    assert from_store == 0b1100    # only the bytes the load needs are reported
    assert all_fwd == 1            # all bytes the load needs came from the store


@cocotb.test()
async def test_wraparound_age_order(dut):
    """Head at slot 6: age order is 6, 7, 0. Slot 0 is the youngest older store."""
    stores = {6: (0x200, 0b0001, replicate(0x11, 1)),
              7: (0x200, 0b0001, replicate(0x22, 1)),
              0: (0x200, 0b0001, replicate(0x33, 1))}
    # head pointer 6, load allocated when tail was 9 (slot 1 next, wrap bit set)
    data, _, _ = await run(dut, stores, 6, 9, 0x200, 0b0001)
    assert data & 0xFF == 0x33, f"got byte {data & 0xFF:#x}"


@cocotb.test()
async def test_wraparound_excludes_younger(dut):
    """Same queue, but the load arrived when the tail was at slot 0 (pointer 8)."""
    stores = {6: (0x200, 0b0001, replicate(0x11, 1)),
              7: (0x200, 0b0001, replicate(0x22, 1)),
              0: (0x200, 0b0001, replicate(0x33, 1))}
    data, _, _ = await run(dut, stores, 6, 8, 0x200, 0b0001)
    assert data & 0xFF == 0x22, f"got byte {data & 0xFF:#x}"