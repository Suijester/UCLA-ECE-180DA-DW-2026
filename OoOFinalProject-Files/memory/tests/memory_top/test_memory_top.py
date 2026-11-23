import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

MEM_LOAD = 1
MEM_STORE = 2
MEM_WORD = 2


async def settle():
    await Timer(1, unit="ns")


async def start(dut):
    dut.clk.value = 0
    dut.rst_n.value = 0
    for name in (
        "disp_valid", "disp_mem_cmd", "disp_mem_size", "disp_tag", "disp_pdst",
        "issue_valid", "issue_mem_cmd", "issue_mem_size", "issue_tag",
        "source_1", "source_2", "issue_immediate", "retire_valid", "retire_tag",
        "rob_head_tag", "branch_resolve_valid", "branch_mispredict",
        "ram_request_ready", "ram_response_valid", "ram_read_data",
    ):
        getattr(dut, name).value = 0
    dut.result_ready.value = 1
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for _ in range(4):
        await RisingEdge(dut.clk)
    await Timer(1, unit="ns")
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await settle()


async def dispatch(dut, cmd, tag):
    dut.disp_mem_cmd.value = cmd
    dut.disp_mem_size.value = MEM_WORD
    dut.disp_tag.value = tag
    dut.disp_pdst.value = 5
    dut.disp_valid.value = 1
    await settle()
    assert int(dut.disp_ready.value) == 1, f"dispatch blocked for tag {tag}"
    await RisingEdge(dut.clk)
    await settle()
    dut.disp_valid.value = 0
    await settle()


@cocotb.test()
async def reset_is_idle(dut):
    """After reset: empty queues, no issue completion, no RAM transaction."""
    await start(dut)
    assert int(dut.busy.value) == 0, "memory_top should start empty"
    assert int(dut.result_valid.value) == 0
    assert int(dut.ram_request_valid.value) == 0
    dut.disp_mem_cmd.value = MEM_LOAD
    await settle()
    assert int(dut.disp_ready.value) == 1


@cocotb.test()
async def dispatch_one_load(dut):
    """Dispatching a load makes the subsystem busy; matching tag can issue."""
    await start(dut)
    await dispatch(dut, MEM_LOAD, tag=3)
    assert int(dut.busy.value) == 1
    dut.issue_mem_cmd.value = MEM_LOAD
    dut.issue_mem_size.value = MEM_WORD
    dut.issue_tag.value = 3
    dut.source_1.value = 0x100
    dut.issue_immediate.value = 0
    await settle()
    assert int(dut.issue_ready.value) == 1, "allocated load not found by ROB tag"
    dut.issue_valid.value = 1
    await RisingEdge(dut.clk)
    await settle()
    dut.issue_valid.value = 0
    await settle()
    assert int(dut.issue_ready.value) == 0, "load unexpectedly accepted twice"


@cocotb.test()
async def dispatch_one_store(dut):
    """Store queue accepts a store and recognizes its issue tag."""
    await start(dut)
    await dispatch(dut, MEM_STORE, tag=4)
    assert int(dut.busy.value) == 1
    dut.issue_mem_cmd.value = MEM_STORE
    dut.issue_mem_size.value = MEM_WORD
    dut.issue_tag.value = 4
    dut.source_1.value = 0x200
    dut.source_2.value = 0x12345678
    dut.issue_immediate.value = 0
    await settle()
    assert int(dut.issue_ready.value) == 1, "allocated store not found by ROB tag"
    dut.issue_valid.value = 1
    await RisingEdge(dut.clk)
    await settle()
    dut.issue_valid.value = 0
    # Store completion can be backpressured/registered; don't assume its cycle.
    assert int(dut.busy.value) == 1, "unretired store disappeared"


@cocotb.test()
async def wrong_tag_does_not_issue(dut):
    """An issue with an unallocated ROB tag must not be accepted."""
    await start(dut)
    await dispatch(dut, MEM_LOAD, tag=2)
    dut.issue_mem_cmd.value = MEM_LOAD
    dut.issue_mem_size.value = MEM_WORD
    dut.issue_tag.value = 7
    dut.issue_valid.value = 1
    await settle()
    assert int(dut.issue_ready.value) == 0
    await RisingEdge(dut.clk)
    await settle()
    dut.issue_valid.value = 0
    dut.issue_tag.value = 2
    await settle()
    assert int(dut.issue_ready.value) == 1, "wrong-tag issue corrupted the load"


# ============================================================
# LQ/SQ integration tests
# ============================================================

async def tick(dut, n=1):
    for _ in range(n):
        await RisingEdge(dut.clk)
        await settle()


async def set_issue(dut, cmd, tag, addr=0x100, data=0x11223344):
    dut.issue_mem_cmd.value = cmd
    dut.issue_mem_size.value = MEM_WORD
    dut.issue_tag.value = tag
    dut.source_1.value = addr
    dut.source_2.value = data
    dut.issue_immediate.value = 0
    await settle()


async def issue(dut, cmd, tag, addr=0x100, data=0x11223344):
    await set_issue(dut, cmd, tag, addr, data)
    assert int(dut.issue_ready.value), f"tag={tag} not issue-ready"
    dut.issue_valid.value = 1
    await tick(dut)
    dut.issue_valid.value = 0
    await settle()


@cocotb.test()
async def load_queue_capacity_and_no_overwrite(dut):
    """Eight loads fill LQ; ninth must stall."""
    await start(dut)

    for tag in range(8):
        await dispatch(dut, MEM_LOAD, tag)

    dut.disp_mem_cmd.value = MEM_LOAD
    dut.disp_tag.value = 8
    dut.disp_valid.value = 1
    await settle()

    assert not int(dut.disp_ready.value), "LQ accepted ninth load"

    await tick(dut, 2)
    assert not int(dut.disp_ready.value)

    dut.disp_valid.value = 0

    for tag in (7, 3, 0):
        await issue(
            dut, MEM_LOAD, tag,
            addr=0x100 + tag * 16
        )

    await set_issue(dut, MEM_LOAD, 8)
    assert not int(dut.issue_ready.value)
    assert int(dut.busy.value)


@cocotb.test()
async def store_queue_capacity_and_no_overwrite(dut):
    """Eight unretired stores fill SQ; ninth must stall."""
    await start(dut)

    for tag in range(8):
        await dispatch(dut, MEM_STORE, tag)

    dut.disp_mem_cmd.value = MEM_STORE
    dut.disp_tag.value = 8
    dut.disp_valid.value = 1
    await settle()

    assert not int(dut.disp_ready.value), "SQ accepted ninth store"

    await tick(dut, 2)
    assert not int(dut.disp_ready.value)

    dut.disp_valid.value = 0

    await set_issue(dut, MEM_STORE, 8)
    assert not int(dut.issue_ready.value)


@cocotb.test()
async def independent_load_store_capacity(dut):
    """A full LQ must not block SQ dispatch."""
    await start(dut)

    for tag in range(8):
        await dispatch(dut, MEM_LOAD, tag)

    dut.disp_mem_cmd.value = MEM_LOAD
    await settle()
    assert not int(dut.disp_ready.value)

    await dispatch(dut, MEM_STORE, 9)

    await set_issue(dut, MEM_STORE, 9, addr=0x400)
    assert int(dut.issue_ready.value), (
        "Full LQ blocked an allocated store"
    )

    dut.disp_mem_cmd.value = MEM_LOAD
    await settle()
    assert not int(dut.disp_ready.value)


@cocotb.test()
async def out_of_order_load_issue_tags(dut):
    """Loads may issue in a different order than dispatch."""
    await start(dut)

    for tag in (1, 2, 3, 4):
        await dispatch(dut, MEM_LOAD, tag)

    for tag in (4, 2, 1, 3):
        await issue(
            dut, MEM_LOAD, tag,
            addr=0x800 + tag * 16
        )

        await set_issue(dut, MEM_LOAD, tag)
        assert not int(dut.issue_ready.value), (
            f"Duplicate issue accepted for tag {tag}"
        )

    await set_issue(dut, MEM_LOAD, 5)
    assert not int(dut.issue_ready.value)


@cocotb.test()
async def retirement_before_execution_does_not_free_load(dut):
    """An unexecuted load must not leave the LQ."""
    await start(dut)

    await dispatch(dut, MEM_LOAD, 3)

    dut.retire_tag.value = 3
    dut.retire_valid.value = 1

    await tick(dut, 2)

    dut.retire_valid.value = 0

    await set_issue(dut, MEM_LOAD, 3)

    assert int(dut.issue_ready.value), (
        "Unexecuted load was incorrectly freed"
    )
    assert int(dut.busy.value)


@cocotb.test()
async def speculative_stores_squashed_on_mispredict(dut):
    """Speculative stores should be removed on mispredict."""
    await start(dut)

    dut.disp_under_branch.value = 0
    await dispatch(dut, MEM_STORE, 1)

    dut.disp_under_branch.value = 1
    await dispatch(dut, MEM_STORE, 2)
    await dispatch(dut, MEM_STORE, 3)

    dut.disp_under_branch.value = 0
    dut.branch_resolve_valid.value = 1
    dut.branch_mispredict.value = 1

    await tick(dut)

    dut.branch_resolve_valid.value = 0
    dut.branch_mispredict.value = 0

    await set_issue(dut, MEM_STORE, 2)
    assert not int(dut.issue_ready.value), (
        "Squashed store tag=2 still issuable"
    )

    await set_issue(dut, MEM_STORE, 3)
    assert not int(dut.issue_ready.value), (
        "Squashed store tag=3 still issuable"
    )

    await set_issue(dut, MEM_STORE, 1)
    assert int(dut.issue_ready.value), (
        "Older non-speculative store was squashed"
    )


@cocotb.test()
async def store_completion_stable_under_backpressure(dut):
    """Store completion must remain stable while result_ready=0."""
    await start(dut)

    dut.result_ready.value = 0

    await dispatch(dut, MEM_STORE, 5)
    await issue(
        dut, MEM_STORE, 5,
        addr=0x500,
        data=0xAABBCCDD
    )

    observed = False

    for _ in range(6):
        if int(dut.result_valid.value):
            observed = True
            assert int(dut.result_tag.value) == 5
            break
        await tick(dut)

    assert observed, (
        "Store completion not produced within 6 cycles"
    )

    for _ in range(4):
        assert int(dut.result_valid.value), (
            "result_valid dropped under backpressure"
        )
        assert int(dut.result_tag.value) == 5, (
            "Completion ROB tag changed while stalled"
        )
        await tick(dut)

    dut.result_ready.value = 1
    await tick(dut, 2)

    assert not int(dut.result_valid.value), (
        "Completion not consumed after ready"
    )


# ============================================================
# cache hierarchy integration tests
# ============================================================

async def cache_tick(dut, cycles=1):
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        await settle()


async def cache_issue(dut, cmd, tag, addr, data=0):
    dut.issue_mem_cmd.value = cmd
    dut.issue_mem_size.value = MEM_WORD
    dut.issue_tag.value = tag
    dut.source_1.value = addr
    dut.source_2.value = data
    dut.issue_immediate.value = 0

    await settle()
    assert int(dut.issue_ready.value), f"Tag {tag} not ready"

    dut.issue_valid.value = 1
    await cache_tick(dut)
    dut.issue_valid.value = 0
    await settle()


async def wait_for_ram_request(dut, timeout=200):
    for _ in range(timeout):
        await settle()
        if int(dut.ram_request_valid.value):
            return (
                int(dut.ram_request_address.value),
                int(dut.ram_request_write.value),
            )
        await cache_tick(dut)

    raise AssertionError("No RAM request observed")


async def wait_for_tag_result(dut, tag, timeout=50):
    for _ in range(timeout):
        await settle()
        if int(dut.result_valid.value):
            if int(dut.result_tag.value) == tag:
                value = int(dut.result_value.value)
                await cache_tick(dut)
                return value
        await cache_tick(dut)

    raise AssertionError(f"No completion for ROB tag {tag}")


@cocotb.test()
async def cold_load_reaches_ram_interface(dut):
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    await dispatch(dut, MEM_LOAD, 1)
    await cache_issue(dut, MEM_LOAD, 1, 0x1000)

    address, is_write = await wait_for_ram_request(dut)

    assert is_write == 0
    assert address == 0x1000, (
        f"Unexpected RAM address: {address:#x}"
    )


@cocotb.test()
async def ram_request_stable_under_backpressure(dut):
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    await dispatch(dut, MEM_LOAD, 1)
    await cache_issue(dut, MEM_LOAD, 1, 0x2000)

    address, is_write = await wait_for_ram_request(dut)

    for _ in range(8):
        await cache_tick(dut)
        assert int(dut.ram_request_valid.value)
        assert int(dut.ram_request_address.value) == address
        assert int(dut.ram_request_write.value) == is_write


@cocotb.test()
async def no_false_load_completion_without_ram(dut):
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    await dispatch(dut, MEM_LOAD, 1)
    await cache_issue(dut, MEM_LOAD, 1, 0x3000)

    await wait_for_ram_request(dut)

    for _ in range(20):
        await settle()
        assert not int(dut.result_valid.value), (
            "Cold load completed without memory data"
        )
        await cache_tick(dut)

    assert int(dut.busy.value)


@cocotb.test()
async def same_line_loads_without_ram(dut):
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    await dispatch(dut, MEM_LOAD, 1)
    await dispatch(dut, MEM_LOAD, 2)

    await cache_issue(dut, MEM_LOAD, 1, 0x4000)
    await cache_issue(dut, MEM_LOAD, 2, 0x4004)

    await wait_for_ram_request(dut)

    for _ in range(20):
        await settle()
        assert not int(dut.result_valid.value), (
            "Load completed without a cache fill"
        )
        await cache_tick(dut)

    assert int(dut.busy.value)


@cocotb.test()
async def full_store_forwarding_without_ram(dut):
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    await dispatch(dut, MEM_STORE, 1)
    await dispatch(dut, MEM_LOAD, 2)

    await cache_issue(
        dut, MEM_STORE, 1,
        addr=0x5000,
        data=0xAABBCCDD
    )

    await wait_for_tag_result(dut, 1)

    await cache_issue(dut, MEM_LOAD, 2, addr=0x5000)
    value = await wait_for_tag_result(dut, 2)

    assert value == 0xAABBCCDD, (
        f"Expected 0xAABBCCDD, got {value:#x}"
    )

    assert not int(dut.ram_request_valid.value)


@cocotb.test()
async def independent_load_addresses(dut):
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    addresses = [0x6000, 0x7000, 0x8000]

    for tag, address in enumerate(addresses, start=1):
        await dispatch(dut, MEM_LOAD, tag)

    for tag, address in enumerate(addresses, start=1):
        await cache_issue(dut, MEM_LOAD, tag, address)

    await wait_for_ram_request(dut)

    for _ in range(20):
        await settle()
        assert not int(dut.result_valid.value), (
            "Unexpected completion without RAM data"
        )
        await cache_tick(dut)

    assert int(dut.busy.value)

# ============================================================
# memory ordering / mshr
# ============================================================

@cocotb.test()
async def load_stalls_on_unknown_older_store(dut):
    """A load must not bypass an older store with unknown address."""
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    await dispatch(dut, MEM_STORE, 1)
    await dispatch(dut, MEM_LOAD, 2)

    # Store 1 has not issued, so its address is unknown.
    await cache_issue(dut, MEM_LOAD, 2, 0x1000)

    for _ in range(15):
        await settle()
        assert not int(dut.result_valid.value), (
            "Load completed past an unresolved older store"
        )
        assert not int(dut.ram_request_valid.value), (
            "Load accessed RAM before older store address resolved"
        )
        await cache_tick(dut)


@cocotb.test()
async def youngest_matching_store_forwarding(dut):
    """Load must forward from youngest matching older store."""
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    await dispatch(dut, MEM_STORE, 1)
    await dispatch(dut, MEM_STORE, 2)
    await dispatch(dut, MEM_LOAD, 3)

    # Older store
    await cache_issue(
        dut, MEM_STORE, 1,
        addr=0x2000,
        data=0x11111111
    )
    await wait_for_tag_result(dut, 1)

    # Younger store overwrites the same address
    await cache_issue(
        dut, MEM_STORE, 2,
        addr=0x2000,
        data=0x22222222
    )
    await wait_for_tag_result(dut, 2)

    await cache_issue(dut, MEM_LOAD, 3, 0x2000)

    value = await wait_for_tag_result(dut, 3)

    assert value == 0x22222222, (
        f"Expected youngest store data 0x22222222, "
        f"got {value:#x}"
    )


@cocotb.test()
async def load_forwards_from_matching_older_store(dut):
    """Nonmatching older stores must not override a matching store."""
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    await dispatch(dut, MEM_STORE, 1)
    await dispatch(dut, MEM_STORE, 2)
    await dispatch(dut, MEM_LOAD, 3)

    await cache_issue(
        dut, MEM_STORE, 1,
        addr=0x3000,
        data=0xAAAAAAAA
    )
    await wait_for_tag_result(dut, 1)

    await cache_issue(
        dut, MEM_STORE, 2,
        addr=0x4000,
        data=0xBBBBBBBB
    )
    await wait_for_tag_result(dut, 2)

    await cache_issue(dut, MEM_LOAD, 3, 0x3000)

    value = await wait_for_tag_result(dut, 3)

    assert value == 0xAAAAAAAA, (
        f"Incorrect forwarding source: {value:#x}"
    )


@cocotb.test()
async def unretired_store_does_not_write_ram(dut):
    """An executed but unretired store must not write main memory."""
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    await dispatch(dut, MEM_STORE, 1)

    await cache_issue(
        dut, MEM_STORE, 1,
        addr=0x5000,
        data=0xDEADBEEF
    )

    await wait_for_tag_result(dut, 1)

    # No ROB retirement or head advancement.
    for _ in range(30):
        await settle()
        assert not (
            int(dut.ram_request_valid.value)
            and int(dut.ram_request_write.value)
        ), "Unretired store attempted a RAM write"
        await cache_tick(dut)

    assert int(dut.busy.value), (
        "Unretired store disappeared from memory subsystem"
    )


@cocotb.test()
async def multiple_misses_preserve_stalled_ram_request(dut):
    """Later misses must not overwrite a stalled RAM request."""
    await start(dut)

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0

    for tag in range(1, 5):
        await dispatch(dut, MEM_LOAD, tag)

    # First cold miss
    await cache_issue(dut, MEM_LOAD, 1, 0x6000)

    first_addr, first_write = await wait_for_ram_request(dut)

    assert first_write == 0

    # More loads targeting distinct lines while RAM is stalled.
    for tag, addr in (
        (2, 0x7000),
        (3, 0x8000),
        (4, 0x9000),
    ):
        await cache_issue(dut, MEM_LOAD, tag, addr)

        await settle()

        assert int(dut.ram_request_valid.value), (
            "Pending RAM request disappeared"
        )
        assert int(dut.ram_request_address.value) == first_addr, (
            "New miss overwrote pending RAM request"
        )

    for _ in range(15):
        await cache_tick(dut)

        assert int(dut.ram_request_valid.value)
        assert int(dut.ram_request_address.value) == first_addr
        assert int(dut.ram_request_write.value) == 0

    assert int(dut.busy.value)


# ============================================================
# END-TO-END LOAD TEST
# LQ -> L1 -> MSHR -> L2 -> RAM -> L1 -> LQ -> CPU
# ============================================================

@cocotb.test()
async def end_to_end_load_cache_fill_and_hit(dut):
    await start(dut)

    BASE = 0x1000

    # One 16-byte cache line = four 32-bit words.
    memory = {
        BASE + 0:  0x11223344,
        BASE + 4:  0x55667788,
        BASE + 8:  0x99AABBCC,
        BASE + 12: 0xDDEEFF00,
    }

    ram_reads = []

    # Simple RAM responder.
    # Assumes one outstanding transaction at a time and
    # a response handshake using response_valid/ready.
    async def ram_responder():
        pending = None

        while True:
            # Drive RAM inputs before the active clock edge.
            await FallingEdge(dut.clk)

            dut.ram_request_ready.value = int(pending is None)
            dut.ram_response_valid.value = int(pending is not None)
            dut.ram_read_data.value = (
                pending if pending is not None else 0
            )

            await settle()

            # Capture the handshakes that will occur
            # at the next rising edge.
            accept_req = (
                int(dut.ram_request_valid.value)
                and int(dut.ram_request_ready.value)
            )

            accept_resp = (
                int(dut.ram_response_valid.value)
                and int(dut.ram_response_ready.value)
            )

            if accept_req:
                addr = int(dut.ram_request_address.value)
                is_write = int(dut.ram_request_write.value)

                assert not is_write, (
                    f"Unexpected RAM write at {addr:#x}"
                )

                assert addr in memory, (
                    f"Unexpected RAM address {addr:#x}"
                )

                ram_reads.append(addr)
                next_data = memory[addr]

                dut._log.info(
                    f"RAM READ: addr={addr:#x}, "
                    f"data={next_data:#010x}"
                )

            if accept_resp:
                dut._log.info("RAM RESPONSE ACCEPTED")

            await RisingEdge(dut.clk)

            # Update the RAM model's state after the handshake.
            if accept_resp:
                pending = None

            if accept_req:
                pending = next_data

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0
    dut.ram_read_data.value = 0

    ram_task = cocotb.start_soon(ram_responder())

    # --------------------------------------------------------
    # 1. Cold load: should miss L1/L2 and fetch from RAM.
    # --------------------------------------------------------

    await dispatch(dut, MEM_LOAD, 1)
    await cache_issue(dut, MEM_LOAD, 1, BASE)

    value = await wait_for_tag_result(dut, 1, timeout=500)

    assert value == 0x11223344, (
        f"First load returned {value:#x}, "
        "expected 0x11223344"
    )

    assert len(ram_reads) >= 4, (
        f"Expected a 4-word cache-line fetch, "
        f"observed {len(ram_reads)} RAM reads"
    )

    first_read_count = len(ram_reads)

    dut._log.info(
        f"Cold load passed. RAM reads: {ram_reads}"
    )

    # --------------------------------------------------------
    # 2. Second load: same address should hit in L1.
    # --------------------------------------------------------

    await dispatch(dut, MEM_LOAD, 2)
    await cache_issue(dut, MEM_LOAD, 2, BASE)

    value = await wait_for_tag_result(dut, 2, timeout=100)

    assert value == 0x11223344, (
        f"Second load returned {value:#x}"
    )

    assert len(ram_reads) == first_read_count, (
        "Second load unexpectedly accessed RAM"
    )

    dut._log.info("L1 hit passed")

    # --------------------------------------------------------
    # 3. Third load: another word in the same cache line.
    # --------------------------------------------------------

    await dispatch(dut, MEM_LOAD, 3)
    await cache_issue(dut, MEM_LOAD, 3, BASE + 8)

    value = await wait_for_tag_result(dut, 3, timeout=100)

    assert value == 0x99AABBCC, (
        f"Expected 0x99AABBCC, got {value:#x}"
    )

    assert len(ram_reads) == first_read_count, (
        "Same-line access unexpectedly accessed RAM"
    )

    dut._log.info("Cache-line word selection passed")

    ram_task.cancel()


# ============================================================
# END-TO-END STORE TEST
# SQ -> L1 -> subsequent load -> CPU
# ============================================================



@cocotb.test()
async def end_to_end_store_commit_and_reload(dut):
    await start(dut)

    BASE = 0x1000
    OLD_DATA = 0x11223344
    NEW_DATA = 0xAABBCCDD

    memory = {
        BASE:      OLD_DATA,
        BASE + 4:  0x55667788,
        BASE + 8:  0x99AABBCC,
        BASE + 12: 0xDDEEFF00,
    }

    ram_reads = []

    # Testbench-only RAM responder.
    # One outstanding transaction; responses are held
    # until response_ready is asserted.
    async def ram_responder():
        pending = None

        while True:
            await FallingEdge(dut.clk)

            dut.ram_request_ready.value = int(
                pending is None
            )
            dut.ram_response_valid.value = int(
                pending is not None
            )
            dut.ram_read_data.value = (
                pending if pending is not None else 0
            )

            await settle()

            accept_req = (
                int(dut.ram_request_valid.value)
                and int(dut.ram_request_ready.value)
            )
            accept_resp = (
                int(dut.ram_response_valid.value)
                and int(dut.ram_response_ready.value)
            )

            if accept_req:
                addr = int(dut.ram_request_address.value)
                is_write = int(dut.ram_request_write.value)

                assert not is_write, (
                    "Unexpected RAM write during this test"
                )
                assert addr in memory, (
                    f"Unexpected RAM read address {addr:#x}"
                )

                ram_reads.append(addr)
                next_data = memory[addr]

            await RisingEdge(dut.clk)

            if accept_resp:
                pending = None

            if accept_req:
                pending = next_data

    dut.ram_request_ready.value = 0
    dut.ram_response_valid.value = 0
    dut.ram_read_data.value = 0

    ram_task = cocotb.start_soon(ram_responder())

    # --------------------------------------------------------
    # 1. Preload the cache with the original value.
    # --------------------------------------------------------

    await dispatch(dut, MEM_LOAD, 1)
    await cache_issue(dut, MEM_LOAD, 1, BASE)

    value = await wait_for_tag_result(dut, 1, timeout=500)

    assert value == OLD_DATA, (
        f"Initial load returned {value:#x}"
    )

    assert len(ram_reads) >= 4, (
        "Initial cache-line fill did not reach RAM"
    )

    # Retire the completed load.
    dut.retire_tag.value = 1
    dut.retire_valid.value = 1
    await cache_tick(dut)
    dut.retire_valid.value = 0

    # --------------------------------------------------------
    # 2. Dispatch and execute a store to the same address.
    # --------------------------------------------------------

    await dispatch(dut, MEM_STORE, 2)

    await cache_issue(
        dut, MEM_STORE, 2,
        addr=BASE,
        data=NEW_DATA
    )

    await wait_for_tag_result(dut, 2, timeout=100)

    # --------------------------------------------------------
    # 3. Commit the store.
    #
    # Current SQ uses ROB head advancement to recognize
    # retirement. Move the ROB head past store tag 2.
    # --------------------------------------------------------

    dut.rob_head_tag.value = 3
    await cache_tick(dut, 2)

    # Wait for the SQ to drain into L1.
    for _ in range(100):
        await settle()
        if not int(dut.busy.value):
            break
        await cache_tick(dut)
    else:
        raise AssertionError(
            "Store did not drain after ROB head advanced"
        )

    # --------------------------------------------------------
    # 4. Load the address again.
    #
    # The SQ entry is gone, so the load must obtain
    # the updated value from the cache hierarchy.
    # --------------------------------------------------------

    reads_before_reload = len(ram_reads)

    await dispatch(dut, MEM_LOAD, 3)
    await cache_issue(dut, MEM_LOAD, 3, BASE)

    value = await wait_for_tag_result(dut, 3, timeout=100)

    assert value == NEW_DATA, (
        f"Store data was not visible after commit: "
        f"expected {NEW_DATA:#x}, got {value:#x}"
    )

    assert len(ram_reads) == reads_before_reload, (
        "Reload unexpectedly accessed main memory"
    )

    dut._log.info(
        "PASS: Store committed to L1 and subsequent "
        "load returned updated data"
    )

    ram_task.cancel()
