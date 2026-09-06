# Build tier: full-power cold-cache compilation node. Run transiently;
# ~$0.60/hr prorated (~$15/day).
instance_type       = "c7g.4xlarge"
volume_size         = 80
volume_throughput   = 200

# Build tier has ample RAM; disable the default 4 GiB swapfile.
swap_size_gib      = 0
