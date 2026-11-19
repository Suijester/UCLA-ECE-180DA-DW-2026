"""Unit tests for load_queue.sv (no SQ/L1 instantiation required).

Run from memory/tests/load_queue/: make
These tests drive a manual clock so inputs are stable at each rising edge.
"""
import cocotb
from cocotb.triggers import Timer


async def settle():
    await Timer(1, unit="ns")


def val(signal):
    return int(signal.value)

def request(dut):
    return (val(dut.l1_req_valid), val(dut.l1_req_addr),
            val(dut.l1_req_byte_mask), val(dut.l1_req_ld_id))


async def tick(dut):
    dut.clk.value = 0
    await settle()
    dut.clk.value = 1
    await settle()
    dut.clk.value = 0
    await settle()


async def setup(dut):
    defaults = {
        "clk": 0, "rst_n": 0,
        "disp_valid": 0, "disp_rob_tag": 0,
        "disp_mem_size": 2, "disp_unsigned": 0,
        "word_addr": 0, "byte_offset": 0, "bytes_accessed": 0,
        "misaligned_access": 0, "issue_rob_tag": 0, "issue_valid": 0,
        "retire_valid": 0, "retire_rob_tag": 0,
        "sq_tail": 0,
        "fwd_data": 0, "fwd_bytes_from_store": 0,
        "fwd_all_from_store": 0, "sq_stall": 0,
        "wake_valid": 0, "wake_line_addr": 0,
        "load_out_ready": 0, "l1_req_ready": 0,
        "l1_resp_valid": 0, "l1_resp_hit": 0,
        "l1_resp_ld_id": 0, "l1_resp_data": 0,
    }
    for name, value in defaults.items():
        getattr(dut, name).value = value
    await tick(dut)
    dut.rst_n.value = 1
    await settle()


async def dispatch(dut, tag, *, sq_tail=0, size=2, unsigned=0):
    dut.disp_valid.value = 1
    dut.disp_rob_tag.value = tag
    dut.sq_tail.value = sq_tail
    dut.disp_mem_size.value = size
    dut.disp_unsigned.value = unsigned
    await settle()
    assert val(dut.disp_ready) == 1, "LQ unexpectedly full"
    await tick(dut)
    dut.disp_valid.value = 0
    await settle()


async def issue(dut, tag, addr, *, offset=0, mask=0xF):
    dut.issue_valid.value = 1
    dut.issue_rob_tag.value = tag
    dut.word_addr.value = addr
    dut.byte_offset.value = offset
    dut.bytes_accessed.value = mask
    await settle()
    assert val(dut.issue_ready) == 1, f"tag {tag} not accepted at issue"
    await tick(dut)
    dut.issue_valid.value = 0
    await settle()


@cocotb.test()
async def test_reset(dut):
    await setup(dut)
    assert val(dut.dbg_head) == 0
    assert val(dut.dbg_tail) == 0
    assert val(dut.dbg_count) == 0
    assert val(dut.dbg_valid) == 0
    assert val(dut.disp_ready) == 1
    assert val(dut.check_valid) == 0
    assert val(dut.l1_req_valid) == 0
    assert val(dut.load_out_valid) == 0


@cocotb.test()
async def test_dispatch(dut):
    await setup(dut)
    await dispatch(dut, 3, sq_tail=5, size=0, unsigned=1)
    assert val(dut.dbg_count) == 1
    assert val(dut.dbg_tail) == 1
    assert val(dut.dbg_valid) & 1
    assert val(dut.dbg_addr_valid) == 0
    assert val(dut.check_valid) == 0  # address not ready
    # Issue makes the saved SQ boundary observable.
    await issue(dut, 3, 0x1000, offset=2, mask=0b0100)
    assert val(dut.check_sq_tail) == 5
    assert val(dut.check_byte_mask) == 0b0100


@cocotb.test()
async def test_issue(dut):
    await setup(dut)
    await dispatch(dut, 2)
    dut.issue_rob_tag.value = 7
    await settle()
    assert val(dut.issue_ready) == 0  # wrong ROB tag
    await issue(dut, 2, 0x2000, offset=1, mask=0b0010)
    assert val(dut.check_valid) == 1
    assert val(dut.check_addr) == 0x2000
    assert val(dut.check_byte_mask) == 0b0010
    assert val(dut.dbg_addr_valid) & 1
    dut.issue_rob_tag.value = 2
    await settle()
    assert val(dut.issue_ready) == 0  # cannot issue same entry twice


@cocotb.test()
async def test_oldest_eligible_selection(dut):
    await setup(dut)
    await dispatch(dut, 1)
    await dispatch(dut, 2)
    await dispatch(dut, 3)
    # Second load issues first: first is ineligible (address missing).
    await issue(dut, 2, 0x2000)
    assert val(dut.check_addr) == 0x2000
    assert val(dut.l1_req_ld_id) == 1
    # First load now issues, but second load's request is held.
    await issue(dut, 1, 0x1000)

    assert val(dut.check_addr) == 0x1000
    assert val(dut.l1_req_ld_id) == 1  # Held request stays stable

    # Accept second load's request.
    dut.l1_req_ready.value = 1
    await tick(dut)

    # Now first load can request L1.
    assert val(dut.l1_req_ld_id) == 0


@cocotb.test()
async def test_full_store_forwarding(dut):
    await setup(dut)
    await dispatch(dut, 4, sq_tail=2, size=0, unsigned=1)
    await issue(dut, 4, 0x3000, offset=3, mask=0b1000)

    dut.fwd_all_from_store.value = 1
    dut.fwd_bytes_from_store.value = 0b1000
    dut.fwd_data.value = 0xAB000000
    dut.load_out_ready.value = 0
    await settle()
    assert val(dut.check_valid) == 1
    assert val(dut.l1_req_valid) == 0
    assert val(dut.load_out_valid) == 0  # Forwarding is buffered.

    await tick(dut)  # Capture SQ data.
    assert val(dut.dbg_sq_checked) & 1
    assert val(dut.load_out_valid) == 1
    assert val(dut.load_out) == 0xAB000000
    assert val(dut.load_out_rob_tag) == 4
    assert val(dut.load_out_mem_size) == 0  # MEM_BYTE
    assert val(dut.load_out_byte_offset) == 3
    assert val(dut.load_out_unsigned) == 1
    assert (val(dut.dbg_executed) & 1) == 0

    dut.load_out_ready.value = 1
    await tick(dut)  # Consume buffered result.
    assert val(dut.dbg_executed) & 1
    assert val(dut.load_out_valid) == 0  # No duplicate completion.


@cocotb.test()
async def test_l1_request(dut):
    await setup(dut)
    await dispatch(dut, 5)
    await issue(dut, 5, 0x4000, offset=2, mask=0b1100)
    dut.fwd_all_from_store.value = 0
    await settle()
    assert val(dut.l1_req_valid) == 1
    assert val(dut.l1_req_addr) == 0x4000
    assert val(dut.l1_req_byte_mask) == 0b1100
    assert val(dut.l1_req_ld_id) == 0
    assert val(dut.load_out_valid) == 0
    dut.l1_req_ready.value = 1
    await tick(dut)
    assert val(dut.dbg_sq_checked) & 1
    assert val(dut.dbg_l1_waiting) & 1
    assert val(dut.l1_req_valid) == 0  # request issued only once


@cocotb.test()
async def test_backpressure(dut):
    # TEST 1: L1 request backpressure
    await setup(dut)
    await dispatch(dut, 6)
    await issue(dut, 6, 0x5000)
    dut.l1_req_ready.value = 0
    await settle()

    for cycle in range(3):
        assert val(dut.l1_req_valid) == 1, f"L1 cycle {cycle}: valid dropped"
        assert val(dut.l1_req_addr) == 0x5000, f"L1 cycle {cycle}: address changed"
        await tick(dut)
        assert (val(dut.dbg_sq_checked) & 1) == 0
        assert (val(dut.dbg_l1_waiting) & 1) == 0

    dut.l1_req_ready.value = 1
    await tick(dut)
    dut.l1_req_ready.value = 0
    await settle()
    assert val(dut.l1_req_valid) == 0, "Duplicate L1 request"
    assert val(dut.dbg_l1_waiting) & 1
    assert val(dut.dbg_sq_checked) & 1

    # TEST 2: Fully forwarded result backpressure
    await setup(dut)
    await dispatch(dut, 7)
    await issue(dut, 7, 0x6000)
    dut.fwd_all_from_store.value = 1
    dut.fwd_bytes_from_store.value = 0xF
    dut.fwd_data.value = 0xDEADBEEF
    dut.load_out_ready.value = 0
    await settle()
    assert val(dut.check_valid) == 1, "No load eligible for SQ forwarding"

    await tick(dut)  # Capture SQ result into LQ.
    assert val(dut.load_out_valid) == 1, "Forwarded result not buffered"
    assert val(dut.dbg_sq_checked) & 1

    # Change the SQ inputs: output must come from the buffered copy.
    dut.fwd_all_from_store.value = 0
    dut.fwd_data.value = 0
    await settle()
    for cycle in range(3):
        assert val(dut.load_out_valid) == 1, f"Forward cycle {cycle}: valid dropped"
        assert val(dut.load_out) == 0xDEADBEEF, f"Forward cycle {cycle}: data changed"
        assert val(dut.load_out_rob_tag) == 7
        assert (val(dut.dbg_executed) & 1) == 0
        await tick(dut)

    dut.load_out_ready.value = 1
    await tick(dut)
    dut.load_out_ready.value = 0
    await settle()
    assert val(dut.dbg_executed) & 1
    assert val(dut.load_out_valid) == 0


@cocotb.test()
async def test_retirement(dut):
    await setup(dut)
    await dispatch(dut, 1)
    await dispatch(dut, 2)
    await issue(dut, 1, 0x1000)
    dut.fwd_all_from_store.value = 1
    dut.fwd_bytes_from_store.value = 0xF
    dut.fwd_data.value = 0x12345678
    dut.load_out_ready.value = 0
    await settle()
    assert val(dut.check_valid) == 1
    await tick(dut)  # Capture forwarded data.
    assert val(dut.load_out_valid) == 1
    assert val(dut.load_out) == 0x12345678
    assert (val(dut.dbg_executed) & 1) == 0

    dut.load_out_ready.value = 1
    await tick(dut)  # Result handshake.
    dut.load_out_ready.value = 0
    assert val(dut.dbg_executed) & 1

    # Wrong ROB tag cannot retire head.
    dut.retire_valid.value = 1
    dut.retire_rob_tag.value = 2
    await tick(dut)
    assert val(dut.dbg_count) == 2
    assert val(dut.dbg_head) == 0

    # Correct tag retires the head.
    dut.retire_rob_tag.value = 1
    await tick(dut)
    dut.retire_valid.value = 0
    assert val(dut.dbg_count) == 1
    assert val(dut.dbg_head) == 1
    assert (val(dut.dbg_valid) & 1) == 0
    assert val(dut.dbg_valid) & 0b10


@cocotb.test()
async def test_l1_hit(dut):
    """L1 hit -> buffered result -> backpressure -> result handshake."""
    await setup(dut)
    tag, addr, data = 3, 0x5000, 0xDEADBEEF
    dut.load_out_ready.value = 0
    await dispatch(dut, tag)
    await issue(dut, tag, addr)
    assert val(dut.l1_req_valid) == 1, "L1 request not asserted"
    assert val(dut.l1_req_addr) == addr, "Incorrect L1 address"
    assert val(dut.l1_req_byte_mask) == 0xF
    ld_id = val(dut.l1_req_ld_id)

    dut.l1_req_ready.value = 1
    await tick(dut)  # L1 accepts request.
    dut.l1_req_ready.value = 0
    await settle()
    assert val(dut.l1_req_valid) == 0, "Duplicate L1 request"
    assert (val(dut.dbg_l1_waiting) >> ld_id) & 1
    assert val(dut.load_out_valid) == 0

    # Delay the response to verify LQ stays waiting.
    for _ in range(2):
        await tick(dut)
        assert (val(dut.dbg_l1_waiting) >> ld_id) & 1
        assert val(dut.load_out_valid) == 0

    dut.l1_resp_valid.value = 1
    dut.l1_resp_hit.value = 1
    dut.l1_resp_ld_id.value = ld_id
    dut.l1_resp_data.value = data
    await tick(dut)  # Capture L1 response.
    dut.l1_resp_valid.value = 0
    dut.l1_resp_hit.value = 0
    dut.l1_resp_data.value = 0
    await settle()

    assert ((val(dut.dbg_l1_waiting) >> ld_id) & 1) == 0
    assert val(dut.load_out_valid) == 1, "Result not valid after L1 hit"
    assert val(dut.load_out) == data, "Incorrect load data"
    assert val(dut.load_out_rob_tag) == tag, "Incorrect ROB tag"
    assert (val(dut.dbg_executed) >> ld_id) & 1 == 0

    for cycle in range(3):
        await tick(dut)
        assert val(dut.load_out_valid) == 1, f"Stall cycle {cycle}: result lost"
        assert val(dut.load_out) == data, f"Stall cycle {cycle}: data changed"
        assert val(dut.load_out_rob_tag) == tag
        assert ((val(dut.dbg_executed) >> ld_id) & 1) == 0

    dut.load_out_ready.value = 1
    await tick(dut)  # Downstream consumes result.
    dut.load_out_ready.value = 0
    await settle()
    assert val(dut.load_out_valid) == 0, "Result valid not cleared"
    assert (val(dut.dbg_executed) >> ld_id) & 1


@cocotb.test()
async def test_sq_stall_blocks_load(dut):
    """An unresolved older store blocks both forwarding and L1 access."""
    await setup(dut)
    dut.sq_stall.value = 1
    await dispatch(dut, 9, sq_tail=3)
    await issue(dut, 9, 0x7000)
    dut.fwd_all_from_store.value = 1
    dut.fwd_data.value = 0xCAFEBABE
    await settle()
    for _ in range(3):
        assert val(dut.check_valid) == 1
        assert val(dut.check_sq_tail) == 3
        assert val(dut.l1_req_valid) == 0
        assert val(dut.load_out_valid) == 0
        assert (val(dut.dbg_sq_checked) & 1) == 0
        await tick(dut)
    dut.sq_stall.value = 0
    await settle()
    assert val(dut.l1_req_valid) == 0  # SQ can fully forward
    await tick(dut)
    assert val(dut.load_out_valid) == 1
    assert val(dut.load_out) == 0xCAFEBABE


@cocotb.test()
async def test_sq_stall_then_l1(dut):
    await setup(dut)
    dut.sq_stall.value = 1
    await dispatch(dut, 10)
    await issue(dut, 10, 0x7100)
    assert val(dut.l1_req_valid) == 0
    dut.sq_stall.value = 0
    await settle()
    assert val(dut.l1_req_valid) == 1
    assert val(dut.l1_req_addr) == 0x7100
    dut.l1_req_ready.value = 1
    await tick(dut)
    assert val(dut.dbg_l1_waiting) & 1


@cocotb.test()
async def test_miss_wakeup_retry_hit(dut):
    await setup(dut)
    await dispatch(dut, 11)
    await issue(dut, 11, 0x1004)
    dut.l1_req_ready.value = 1
    await settle()
    ld_id = val(dut.l1_req_ld_id)
    await tick(dut)  # initial request accepted
    dut.l1_req_ready.value = 0
    dut.l1_resp_valid.value = 1
    dut.l1_resp_hit.value = 0
    dut.l1_resp_ld_id.value = ld_id
    await tick(dut)  # miss response
    dut.l1_resp_valid.value = 0
    await settle()
    assert val(dut.l1_req_valid) == 0
    assert val(dut.load_out_valid) == 0

    dut.wake_valid.value = 1
    dut.wake_line_addr.value = 0x101  # wrong line (16-byte lines)
    await tick(dut)
    assert val(dut.l1_req_valid) == 0

    dut.wake_line_addr.value = 0x100  # correct line
    await tick(dut)
    dut.wake_valid.value = 0
    await settle()
    assert val(dut.l1_req_valid) == 1
    assert val(dut.l1_req_addr) == 0x1004
    assert val(dut.l1_req_ld_id) == ld_id
    dut.l1_req_ready.value = 1
    await tick(dut)  # retry accepted
    dut.l1_req_ready.value = 0
    dut.l1_resp_valid.value = 1
    dut.l1_resp_hit.value = 1
    dut.l1_resp_data.value = 0x12345678
    await tick(dut)
    dut.l1_resp_valid.value = 0
    await settle()
    assert val(dut.load_out_valid) == 1
    assert val(dut.load_out) == 0x12345678
    assert val(dut.load_out_rob_tag) == 11


@cocotb.test()
async def test_early_wakeup_before_miss_response(dut):
    await setup(dut)
    await dispatch(dut, 12)
    await issue(dut, 12, 0x2000)
    dut.l1_req_ready.value = 1
    ld_id = val(dut.l1_req_ld_id)
    await tick(dut)
    dut.l1_req_ready.value = 0
    dut.wake_valid.value = 1
    dut.wake_line_addr.value = 0x200
    await tick(dut)  # wake before response
    dut.wake_valid.value = 0
    dut.l1_resp_valid.value = 1
    dut.l1_resp_hit.value = 0
    dut.l1_resp_ld_id.value = ld_id
    await tick(dut)
    dut.l1_resp_valid.value = 0
    await settle()
    assert val(dut.l1_req_valid) == 1, "Early wake should trigger retry"
    assert val(dut.l1_req_ld_id) == ld_id


@cocotb.test()
async def test_same_cycle_wakeup_and_miss_response(dut):
    await setup(dut)
    await dispatch(dut, 13)
    await issue(dut, 13, 0x3000)
    dut.l1_req_ready.value = 1
    ld_id = val(dut.l1_req_ld_id)
    await tick(dut)
    dut.l1_req_ready.value = 0
    dut.wake_valid.value = 1
    dut.wake_line_addr.value = 0x300
    dut.l1_resp_valid.value = 1
    dut.l1_resp_hit.value = 0
    dut.l1_resp_ld_id.value = ld_id
    await tick(dut)
    dut.wake_valid.value = 0
    dut.l1_resp_valid.value = 0
    await settle()
    assert val(dut.l1_req_valid) == 1
    assert val(dut.l1_req_ld_id) == ld_id

@cocotb.test()
async def test_held_partial_forwarding_and_second_load(dut):
    """Stalled A must not change when B appears; forwarded byte survives SQ changes."""
    await setup(dut)
    await dispatch(dut, 11)
    await issue(dut, 11, 0x1000, mask=0xF)

    # SQ forwards byte lane 1 of A; L1 supplies the other three lanes.
    dut.fwd_data.value = 0x0000AA00
    dut.fwd_bytes_from_store.value = 0b0010
    dut.fwd_all_from_store.value = 0
    dut.l1_req_ready.value = 0
    await settle()
    a_req = request(dut)
    assert a_req == (1, 0x1000, 0xF, 0)
    await tick(dut)  # Request A is now held; forwarding snapshot captured.

    # B becomes eligible while A is held. SQ output now belongs to B.
    await dispatch(dut, 12)
    await issue(dut, 12, 0x2000, mask=0xF)
    dut.fwd_data.value = 0x00000000
    dut.fwd_bytes_from_store.value = 0
    await settle()
    assert val(dut.check_valid) == 1
    assert val(dut.check_addr) == 0x2000
    for _ in range(3):
        assert request(dut) == a_req, "Held L1 request changed under backpressure"
        await tick(dut)

    dut.l1_req_ready.value = 1
    await settle()
    assert request(dut) == a_req
    await tick(dut)  # A handshakes.
    dut.l1_req_ready.value = 0
    await settle()
    assert request(dut) == (1, 0x2000, 0xF, 1), "B should be next"

    # Response for A: memory=0x11223344, SQ lane 1=0xAA => 0x1122AA44.
    dut.l1_resp_valid.value = 1
    dut.l1_resp_hit.value = 1
    dut.l1_resp_ld_id.value = 0
    dut.l1_resp_data.value = 0x11223344
    await tick(dut)
    dut.l1_resp_valid.value = 0
    await settle()
    assert val(dut.load_out_valid) == 1
    assert val(dut.load_out_rob_tag) == 11
    assert val(dut.load_out) == 0x1122AA44, (
        f"Incorrect byte merge: got 0x{val(dut.load_out):08x}"
    )


@cocotb.test()
async def test_retry_cannot_preempt_held_new_request(dut):
    """A retry becoming eligible must not replace an already-stalled B request."""
    await setup(dut)
    await dispatch(dut, 21)
    await issue(dut, 21, 0x3000)
    dut.l1_req_ready.value = 1
    await tick(dut)  # A accepted by L1.
    dut.l1_req_ready.value = 0
    dut.l1_resp_valid.value = 1
    dut.l1_resp_hit.value = 0
    dut.l1_resp_ld_id.value = 0
    await tick(dut)  # A misses and waits for wakeup.
    dut.l1_resp_valid.value = 0

    await dispatch(dut, 22)
    await issue(dut, 22, 0x4000)
    await settle()
    b_req = request(dut)
    assert b_req == (1, 0x4000, 0xF, 1)
    await tick(dut)  # B becomes held.

    # Wake A; A's retry now has priority in the arbiter, but not over held B.
    dut.wake_valid.value = 1
    dut.wake_line_addr.value = 0x3000 >> 4  # OFFSET_BITS=4 in mem_pkg
    await tick(dut)
    dut.wake_valid.value = 0
    await settle()
    assert request(dut) == b_req, "Retry preempted stalled B"

    dut.l1_req_ready.value = 1
    await tick(dut)  # B accepted first.
    dut.l1_req_ready.value = 0
    await settle()
    assert request(dut) == (1, 0x3000, 0xF, 0), "A retry should follow B"


@cocotb.test()
async def test_full_forward_while_another_request_held(dut):
    """An SQ-only load may finish while an unrelated L1 request is stalled."""
    await setup(dut)
    await dispatch(dut, 31)
    await issue(dut, 31, 0x5000)
    dut.l1_req_ready.value = 0
    await settle()
    a_req = request(dut)
    await tick(dut)  # Hold A.

    await dispatch(dut, 32)
    await issue(dut, 32, 0x6000)
    dut.fwd_all_from_store.value = 1
    dut.fwd_bytes_from_store.value = 0xF
    dut.fwd_data.value = 0xCAFEBABE
    await settle()
    assert request(dut) == a_req
    await tick(dut)  # B completes via SQ, A stays held.
    assert request(dut) == a_req
    assert val(dut.load_out_valid) == 1
    assert val(dut.load_out_rob_tag) == 32
    assert val(dut.load_out) == 0xCAFEBABE

