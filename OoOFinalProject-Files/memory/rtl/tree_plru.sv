import mem_pkg::*;

module tree_plru (
    input logic clk,
    input logic rst_n,

    input logic cache_touched,
    input logic [L1_INDEX_BITS-1:0] set_touched,
    input l1_way_ptr_t way_touched,

    input logic [L1_INDEX_BITS-1:0] victim_set,
    output l1_way_ptr_t victim_way
);

    // victim/eviction logic
    logic [L1_WAYS-2:0] tree [0:L1_SETS-1];
    logic [L1_WAYS-2:0] victim_tree;

    assign victim_tree = tree[victim_set];

    // find victim via tree traversal
    int node_index_victim;
    always_comb begin
        node_index_victim = 0;
        for (int i = $clog2(L1_WAYS)-1; i >= 0; i--) begin : find_victim
            victim_way[i] = victim_tree[node_index_victim];
            node_index_victim = (node_index_victim * 2) + victim_tree[node_index_victim] + 1;
        end
    end

    // touched-cache update logic 
    logic [L1_WAYS-2:0] next_tree;
    logic [L1_WAYS-2:0] update_tree;

    assign update_tree = tree[set_touched];

    // find next tree via traversal
    int node_index_update;
    always_comb begin
        next_tree = update_tree;
        node_index_update = 0;
        for (int i = $clog2(L1_WAYS)-1; i >= 0; i--) begin : gen_tree
            next_tree[node_index_update] = ~way_touched[i];
            node_index_update = (node_index_update * 2) + way_touched[i] + 1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 0; i < L1_SETS; i++) 
                tree[i] <= '0;

        end else if (cache_touched) begin
            tree[set_touched] <= next_tree;
        end
    end

endmodule