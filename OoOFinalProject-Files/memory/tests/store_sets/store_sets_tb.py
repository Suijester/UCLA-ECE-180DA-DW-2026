"""cocotb tests for store_sets.sv

Each PC maps to SSIT entry pc[8:2], so the PCs below are 4-byte aligned and
distinct. The wrapper sets SSIT_CLEAR_CYCLES = 64 so the periodic clear can be
tested quickly; every other test finishes well inside 64 cycles.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

CLEAR_CYCLES = 64

LD_A, LD_B = 0x100, 0x104          # load PCs
ST_A, ST_B = 0x200, 0x204          # store PCs


def idle_inputs(dut):
    dut.disp_valid.value = 0
    dut.disp_is_load.value = 0
    dut.disp_is_store.value = 0
    dut.disp_pc0.value = 0
    dut.disp_pc1.value = 0
    dut.disp_st_ptr0.value = 0
    dut.disp_st_ptr1.value = 0
    dut.st_issue_valid.value = 0
    dut.st_issue_ptr.value = 0
    dut.viol_valid.value = 0
    dut.viol_load_pc.value = 0
    dut.viol_store_pc.value = 0
    dut.flush_all.value = 0
    dut.sq_squash_mask.value = 0


async def settle():
    await Timer(1, units="ns")


async def tick(dut):
    """Advance one clock; return just after the next falling edge."""
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    idle_inputs(dut)
    dut.rst_n.value = 0
    await tick(dut)
    await tick(dut)
    dut.rst_n.value = 1
    await settle()


async def dispatch(dut, lane0, lane1=None):
    """Dispatch one or two instructions for one cycle.

    Each lane is ("load", pc) or ("store", pc, sq_ptr). Returns
    [(wait_valid, wait_ptr) for lane 0, ... for lane 1].
    """
    valid = is_load = is_store = 0
    for lane, op in enumerate((lane0, lane1)):
        if op is None:
            continue
        valid |= 1 << lane
        if op[0] == "load":
            is_load |= 1 << lane
        else:
            is_store |= 1 << lane
            getattr(dut, f"disp_st_ptr{lane}").value = op[2]
        getattr(dut, f"disp_pc{lane}").value = op[1]
    dut.disp_valid.value = valid
    dut.disp_is_load.value = is_load
    dut.disp_is_store.value = is_store
    await settle()
    waits = int(dut.disp_wait_valid.value)
    result = [((waits >> 0) & 1, int(dut.disp_wait_st_ptr0.value)),
              ((waits >> 1) & 1, int(dut.disp_wait_st_ptr1.value))]
    await tick(dut)
    idle_inputs(dut)
    await settle()
    return result


async def train(dut, load_pc, store_pc):
    """Report one memory-order violation between a load and a store."""
    dut.viol_valid.value = 1
    dut.viol_load_pc.value = load_pc
    dut.viol_store_pc.value = store_pc
    await tick(dut)
    idle_inputs(dut)
    await settle()


async def issue(dut, sq_ptr):
    dut.st_issue_valid.value = 1
    dut.st_issue_ptr.value = sq_ptr
    await tick(dut)
    idle_inputs(dut)
    await settle()



@cocotb.test()
async def test_untrained_load_does_not_wait(dut):
    """Before any violation, nothing is in a set, so nothing waits."""
    await setup(dut)
    await dispatch(dut, ("store", ST_A, 1))
    (wait, _), _ = await dispatch(dut, ("load", LD_A))
    assert wait == 0, "an untrained load was told to wait"


@cocotb.test()
async def test_trained_load_waits_for_store(dut):
    """After a violation, the load waits for the last dispatched store of its set."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    await dispatch(dut, ("store", ST_A, 3))
    (wait, ptr), _ = await dispatch(dut, ("load", LD_A))
    assert wait == 1, "trained load did not wait"
    assert ptr == 3, f"waits for SQ pointer {ptr}, expected 3"


@cocotb.test()
async def test_unrelated_load_does_not_wait(dut):
    """Training one pair must not affect a different load."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    await dispatch(dut, ("store", ST_A, 3))
    (wait, _), _ = await dispatch(dut, ("load", LD_B))
    assert wait == 0, "an untrained load waited"


@cocotb.test()
async def test_same_bundle_bypass(dut):
    """Store in lane 0 and its dependent load in lane 1: the load waits for lane 0."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    (w0, _), (w1, p1) = await dispatch(dut, ("store", ST_A, 5), ("load", LD_A))
    assert w0 == 0, "the store had no earlier store to wait for"
    assert w1 == 1 and p1 == 5, f"lane 1 wait={w1} ptr={p1}, expected wait on 5"




@cocotb.test()
async def test_store_chaining(dut):
    """Two stores in one set: the second waits for the first, the load for the second."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    await train(dut, LD_A, ST_B)                     # ST_B joins the load's set
    await dispatch(dut, ("store", ST_A, 1))
    (w, p), _ = await dispatch(dut, ("store", ST_B, 2))
    assert w == 1 and p == 1, f"second store wait={w} ptr={p}, expected wait on 1"
    (w, p), _ = await dispatch(dut, ("load", LD_A))
    assert w == 1 and p == 2, f"load wait={w} ptr={p}, expected wait on 2"


@cocotb.test()
async def test_lane1_store_wins_lfst(dut):
    """Two stores of one set in one bundle: lane 1 is younger and becomes the last store."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    await train(dut, LD_A, ST_B)
    _, (w1, p1) = await dispatch(dut, ("store", ST_A, 1), ("store", ST_B, 2))
    assert w1 == 1 and p1 == 1, "lane 1 store did not chain behind lane 0"
    (w, p), _ = await dispatch(dut, ("load", LD_A))
    assert w == 1 and p == 2, f"load waits on {p}, expected the lane 1 store (2)"


@cocotb.test()
async def test_issue_clears_lfst(dut):
    """Once the last store issues, a later load no longer waits."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    await dispatch(dut, ("store", ST_A, 4))
    await issue(dut, 4)
    (wait, _), _ = await dispatch(dut, ("load", LD_A))
    assert wait == 0, "load still waits for a store that already issued"


@cocotb.test()
async def test_issue_of_older_store_keeps_newer(dut):
    """An older store issuing must not clear the entry of a newer store in its set."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    await dispatch(dut, ("store", ST_A, 1))
    await dispatch(dut, ("store", ST_A, 2))
    await issue(dut, 1)
    (w, p), _ = await dispatch(dut, ("load", LD_A))
    assert w == 1 and p == 2, f"load wait={w} ptr={p}, expected wait on 2"



@cocotb.test()
async def test_squash_clears_lfst(dut):
    """A store squashed by a mispredict leaves the LFST."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    await dispatch(dut, ("store", ST_A, 6))
    dut.sq_squash_mask.value = 1 << 6
    await tick(dut)
    idle_inputs(dut)
    await settle()
    (wait, _), _ = await dispatch(dut, ("load", LD_A))
    assert wait == 0, "load waits for a squashed store"


@cocotb.test()
async def test_flush_clears_lfst_keeps_ssit(dut):
    """A full flush empties the LFST but keeps what was learned in the SSIT."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    await dispatch(dut, ("store", ST_A, 3))
    dut.flush_all.value = 1
    await tick(dut)
    idle_inputs(dut)
    await settle()
    (wait, _), _ = await dispatch(dut, ("load", LD_A))
    assert wait == 0, "load waits for a flushed store"
    await dispatch(dut, ("store", ST_A, 4))          # the pair is still trained
    (w, p), _ = await dispatch(dut, ("load", LD_A))
    assert w == 1 and p == 4, "flush also erased the trained pair"


@cocotb.test()
async def test_merge_takes_smaller_set(dut):
    """Two sets merge when a violation links them; both PCs take the smaller id."""
    await setup(dut)
    await train(dut, LD_A, ST_A)                     # set 0
    await train(dut, LD_B, ST_B)                     # set 1
    await dispatch(dut, ("store", ST_B, 7))
    (wait, _), _ = await dispatch(dut, ("load", LD_A))
    assert wait == 0, "LD_A waited on a store from another set"
    await train(dut, LD_A, ST_B)                     # links them: ST_B moves to set 0
    await dispatch(dut, ("store", ST_B, 2))
    (w, p), _ = await dispatch(dut, ("load", LD_A))
    assert w == 1 and p == 2, f"after merge LD_A wait={w} ptr={p}, expected wait on 2"


@cocotb.test()
async def test_periodic_clear_forgets_pairs(dut):
    """After the clear interval, the SSIT is wiped and trained loads stop waiting."""
    await setup(dut)
    await train(dut, LD_A, ST_A)
    for _ in range(CLEAR_CYCLES + 2):
        await tick(dut)
    await dispatch(dut, ("store", ST_A, 1))
    (wait, _), _ = await dispatch(dut, ("load", LD_A))
    assert wait == 0, "SSIT was not cleared after the interval"