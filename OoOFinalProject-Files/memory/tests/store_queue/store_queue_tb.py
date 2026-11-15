"""cocotb tests for store_queue.sv

Timing convention: inputs change right after a falling edge; outputs are
checked 1 ns later (combinational logic settled, state from the last rising edge).
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

SQ_SIZE = 8


def tag(index, gen=0):
    """ROB tag as {generation[1:0], index[3:0]}."""
    return ((gen & 0x3) << 4) | (index & 0xF)


def line_of(word_addr):
    return word_addr >> 4


def idle_inputs(dut):
    dut.alloc_valid.value = 0
    dut.alloc_rob_tag.value = 0
    dut.alloc_under_branch.value = 0
    dut.alloc_word_addr.value = 0
    dut.alloc_bytes_accessed.value = 0
    dut.alloc_write_data.value = 0
    dut.br_resolve_valid.value = 0
    dut.br_mispredict.value = 0
    dut.drain_ready.value = 0
    dut.drain_resp_valid.value = 0
    dut.drain_resp_hit.value = 0
    dut.drain_resp_st_id.value = 0
    dut.wake_valid.value = 0
    dut.wake_line_addr.value = 0


async def settle():
    await Timer(1, units="ns")


async def tick(dut):
    """Advance one clock; return just after the next falling edge."""
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    idle_inputs(dut)
    dut.rob_head_tag.value = tag(0)
    dut.rst_n.value = 0
    await tick(dut)
    await tick(dut)
    dut.rst_n.value = 1
    await settle()


async def alloc(dut, rob_index, addr, data, bytes_en=0xF, under_branch=0):
    """Allocate one store; checks it is accepted and completes the same cycle."""
    dut.alloc_valid.value = 1
    dut.alloc_rob_tag.value = tag(rob_index)
    dut.alloc_word_addr.value = addr
    dut.alloc_write_data.value = data
    dut.alloc_bytes_accessed.value = bytes_en
    dut.alloc_under_branch.value = under_branch
    await settle()
    assert dut.alloc_ready.value == 1, "store queue refused an allocation"
    assert dut.comp_valid.value == 1, "no completion sent for an accepted store"
    assert int(dut.comp_rob_tag.value) == tag(rob_index), "completion carries the wrong ROB tag"
    await tick(dut)
    dut.alloc_valid.value = 0
    await settle()


async def drain_one(dut, expect_addr, expect_data, hit=True):
    """Accept the head's drain request, then answer with an L1 hit or miss."""
    assert dut.drain_valid.value == 1, "expected a drain request"
    assert int(dut.drain_word_addr.value) == expect_addr, (
        f"drained {int(dut.drain_word_addr.value):#x}, expected {expect_addr:#x}")
    assert int(dut.drain_write_data.value) == expect_data
    st_id = int(dut.drain_st_id.value)
    dut.drain_ready.value = 1
    await tick(dut)                      # request accepted at this edge
    dut.drain_ready.value = 0
    await settle()
    assert dut.drain_valid.value == 0, "sent a second request before the response"
    dut.drain_resp_valid.value = 1       # L1 answers one cycle later
    dut.drain_resp_hit.value = 1 if hit else 0
    dut.drain_resp_st_id.value = st_id
    await tick(dut)
    dut.drain_resp_valid.value = 0
    dut.drain_resp_hit.value = 0
    await settle()


@cocotb.test()
async def test_reset_state(dut):
    """After reset the queue is empty and ready."""
    await setup(dut)
    assert dut.sq_empty.value == 1
    assert dut.sq_full.value == 0
    assert dut.alloc_ready.value == 1
    assert dut.drain_valid.value == 0


@cocotb.test()
async def test_fill_to_full(dut):
    """Eight allocations fill the queue; the ninth is refused."""
    await setup(dut)
    for i in range(SQ_SIZE):
        await alloc(dut, i, 0x100 + 4 * i, i)
    assert dut.sq_full.value == 1
    dut.alloc_valid.value = 1
    await settle()
    assert dut.alloc_ready.value == 0, "accepted a store while full"
    assert dut.comp_valid.value == 0, "completed a store it did not accept"
    dut.alloc_valid.value = 0


@cocotb.test()
async def test_no_drain_before_retire(dut):
    """A store at the ROB head (distance 0) is not retired and must not drain."""
    await setup(dut)
    await alloc(dut, 0, 0x200, 0xAAAA)
    dut.rob_head_tag.value = tag(0)      # store is AT the head
    for _ in range(3):
        await tick(dut)
        await settle()
        assert dut.drain_valid.value == 0, "drained a store before it retired"


@cocotb.test()
async def test_retire_and_drain_in_order(dut):
    """Stores drain in program order once the ROB head passes them."""
    await setup(dut)
    stores = [(0, 0x300, 0x11), (1, 0x304, 0x22), (2, 0x308, 0x33)]
    for rob, addr, data in stores:
        await alloc(dut, rob, addr, data)
    dut.rob_head_tag.value = tag(2)      # stores 0 and 1 retired, store 2 at the head
    await tick(dut)
    await settle()
    await drain_one(dut, 0x300, 0x11)
    await drain_one(dut, 0x304, 0x22)
    await tick(dut)
    await settle()
    assert dut.drain_valid.value == 0, "drained store 2 before it retired"
    dut.rob_head_tag.value = tag(3)
    await tick(dut)
    await settle()
    await drain_one(dut, 0x308, 0x33)
    assert dut.sq_empty.value == 1


@cocotb.test()
async def test_retire_across_generation_wrap(dut):
    """Retirement uses the modular tag distance, so it works across the ROB wrap."""
    await setup(dut)
    await alloc(dut, 15, 0x400, 0x44)               # gen 0, index 15
    dut.rob_head_tag.value = tag(0, gen=1)          # next tag after it: gen 1, index 0
    await tick(dut)
    await settle()
    await drain_one(dut, 0x400, 0x44)
    assert dut.sq_empty.value == 1


@cocotb.test()
async def test_miss_waits_for_wake_then_retries(dut):
    """An L1 miss holds the head until the MSHR wakes its line, then the store retries."""
    await setup(dut)
    await alloc(dut, 0, 0x510, 0x55)
    dut.rob_head_tag.value = tag(1)
    await tick(dut)
    await settle()
    await drain_one(dut, 0x510, 0x55, hit=False)
    for _ in range(3):                               # wake for another line does nothing
        dut.wake_valid.value = 1
        dut.wake_line_addr.value = line_of(0x900)
        await tick(dut)
        await settle()
        assert dut.drain_valid.value == 0, "retried before its own line was filled"
    dut.wake_line_addr.value = line_of(0x510)        # its line is filled
    await tick(dut)
    dut.wake_valid.value = 0
    await settle()
    await drain_one(dut, 0x510, 0x55, hit=True)
    assert dut.sq_empty.value == 1


@cocotb.test()
async def test_wake_same_cycle_as_miss(dut):
    """If the wake lands with the miss response, the store retries instead of hanging."""
    await setup(dut)
    await alloc(dut, 0, 0x620, 0x66)
    dut.rob_head_tag.value = tag(1)
    await tick(dut)
    await settle()
    dut.drain_ready.value = 1
    await tick(dut)
    dut.drain_ready.value = 0
    dut.drain_resp_valid.value = 1
    dut.drain_resp_hit.value = 0
    dut.drain_resp_st_id.value = 0
    dut.wake_valid.value = 1
    dut.wake_line_addr.value = line_of(0x620)
    await tick(dut)
    idle_inputs(dut)
    await settle()
    assert dut.drain_valid.value == 1, "store hung after a same-cycle wake"


@cocotb.test()
async def test_mispredict_squashes_younger_stores(dut):
    """Unretired stores under the branch are freed and the tail rolls back."""
    await setup(dut)
    await alloc(dut, 0, 0x700, 0x70)                 # older than the branch
    await alloc(dut, 1, 0x704, 0x71)
    await alloc(dut, 3, 0x708, 0x72, under_branch=1) # younger than the branch
    await alloc(dut, 4, 0x70C, 0x73, under_branch=1)
    head = int(dut.sq_head.value)
    dut.br_resolve_valid.value = 1
    dut.br_mispredict.value = 1
    await settle()
    assert int(dut.sq_squash_mask.value) == 0b1100, f"mask {int(dut.sq_squash_mask.value):#b}"
    await tick(dut)
    dut.br_resolve_valid.value = 0
    dut.br_mispredict.value = 0
    await settle()
    assert int(dut.sq_valid.value) == 0b0011
    assert int(dut.sq_tail.value) == head + 2, "tail did not roll back to the survivors"
    await alloc(dut, 3, 0x7F0, 0x99)                 # correct-path store reuses slot 2
    assert int(dut.sq_valid.value) == 0b0111


@cocotb.test()
async def test_correct_resolve_clears_under_branch(dut):
    """After a correct resolve, a later mispredict must not drop those stores."""
    await setup(dut)
    await alloc(dut, 0, 0x800, 0x80, under_branch=1)
    dut.br_resolve_valid.value = 1                   # branch resolved correctly
    await tick(dut)
    dut.br_resolve_valid.value = 0
    await alloc(dut, 2, 0x804, 0x81, under_branch=1) # under a new branch
    dut.br_resolve_valid.value = 1
    dut.br_mispredict.value = 1
    await settle()
    assert int(dut.sq_squash_mask.value) == 0b10, "squashed a store from a resolved branch"
    await tick(dut)
    idle_inputs(dut)
    await settle()
    assert int(dut.sq_valid.value) == 0b01


@cocotb.test()
async def test_retired_stores_survive_mispredict(dut):
    """A store that retired is architectural and is never squashed."""
    await setup(dut)
    await alloc(dut, 0, 0x900, 0x90, under_branch=1)
    dut.rob_head_tag.value = tag(1)                  # it retires
    await tick(dut)
    dut.br_resolve_valid.value = 1
    dut.br_mispredict.value = 1
    await settle()
    assert int(dut.sq_squash_mask.value) == 0, "squashed a retired store"
    await tick(dut)
    idle_inputs(dut)
    await settle()
    assert int(dut.sq_valid.value) == 0b1


async def send_head(dut):
    """The L1 accepts the head's request at the next edge."""
    dut.drain_ready.value = 1
    await tick(dut)
    dut.drain_ready.value = 0

@cocotb.test()
async def test_wake_in_send_cycle_then_miss(dut):
    """A wake in the same cycle the request is accepted is remembered for the miss."""
    await setup(dut)
    await alloc(dut, 0, 0xA00, 0xA0)
    dut.rob_head_tag.value = tag(1)
    await tick(dut)
    await settle()
    dut.drain_ready.value = 1                        # request accepted at this edge...
    dut.wake_valid.value = 1                         # ...and the line's wake in the same cycle
    dut.wake_line_addr.value = line_of(0xA00)
    await tick(dut)
    idle_inputs(dut)
    dut.drain_resp_valid.value = 1                   # miss response, no wake this time
    dut.drain_resp_hit.value = 0
    dut.drain_resp_st_id.value = 0
    await tick(dut)
    idle_inputs(dut)
    await settle()
    assert dut.drain_valid.value == 1, "missed the wake from the send cycle and slept"


@cocotb.test()
async def test_wake_while_pending_then_late_miss(dut):
    """A wake between acceptance and a delayed miss response is remembered."""
    await setup(dut)
    await alloc(dut, 0, 0xB00, 0xB0)
    dut.rob_head_tag.value = tag(1)
    await tick(dut)
    await settle()
    await send_head(dut)                             # accepted; response not back yet
    dut.wake_valid.value = 1                         # wake arrives while in flight
    dut.wake_line_addr.value = line_of(0xB00)
    await tick(dut)
    idle_inputs(dut)
    dut.drain_resp_valid.value = 1                   # miss response arrives later
    dut.drain_resp_hit.value = 0
    dut.drain_resp_st_id.value = 0
    await tick(dut)
    idle_inputs(dut)
    await settle()
    assert dut.drain_valid.value == 1, "missed the in-flight wake and slept"

@cocotb.test()
async def test_other_line_wake_in_flight_ignored(dut):
    """A wake for a different line while in flight must not count as ours."""
    await setup(dut)
    await alloc(dut, 0, 0xC00, 0xC0)
    dut.rob_head_tag.value = tag(1)
    await tick(dut)
    await settle()
    await send_head(dut)
    dut.wake_valid.value = 1                         # someone else's line
    dut.wake_line_addr.value = line_of(0xD00)
    await tick(dut)
    idle_inputs(dut)
    dut.drain_resp_valid.value = 1
    dut.drain_resp_hit.value = 0
    dut.drain_resp_st_id.value = 0
    await tick(dut)
    idle_inputs(dut)
    for _ in range(3):
        await settle()
        assert dut.drain_valid.value == 0, "retried on another line's wake"
        await tick(dut)
    dut.wake_valid.value = 1                         # now our line is filled
    dut.wake_line_addr.value = line_of(0xC00)
    await tick(dut)
    idle_inputs(dut)
    await settle()
    await drain_one(dut, 0xC00, 0xC0, hit=True)
    assert dut.sq_empty.value == 1