// RUN: triton-opt %s -split-input-file --allocate-shared-memory --convert-triton-amdgpu-to-llvm=arch=gfx950 | FileCheck %s --check-prefixes=COMMON,GFX950
// RUN: triton-opt %s -split-input-file --allocate-shared-memory --convert-triton-amdgpu-to-llvm=arch=gfx942 | FileCheck %s --check-prefixes=COMMON,GFX942

// COMMON: [[ASYNC_COPY_SCOPE:#.*]] = #llvm.alias_scope<id = "amdgpu.AsyncCopies"
#blocked = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [64, 1], warpsPerCTA = [1, 1], order = [0, 1]}>
#shared = #ttg.swizzled_shared<{vec = 8, perPhase = 8, maxPhase = 2, order = [0, 1]}>
#smem = #ttg.shared_memory
module attributes {"ttg.num-ctas" = 1 : i32, "ttg.num-warps" = 1 : i32, ttg.target = "hip:gfx950", "ttg.threads-per-warp" = 64 : i32} {
  tt.func public @async_copy_alias(%arg0: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32},
                                                         %arg1: !ttg.memdesc<64x1xf16, #shared, #smem, mutable>) {
    // We need the splat to allow the AxisAnalysis to work during lowering
    %ptr = tt.splat %arg0 : !tt.ptr<f16> -> tensor<64x1x!tt.ptr<f16>, #blocked>

    // COMMON: rocdl.global.load.lds {{.*}} {alias_scopes = [[[ASYNC_COPY_SCOPE]]]
    %0 = ttg.async_copy_global_to_local %ptr, %arg1 : tensor<64x1x!tt.ptr<f16>, #blocked> -> <64x1xf16, #shared, #smem, mutable>

    // COMMON: llvm.return
    tt.return
  }
}

// -----

// COMMON: [[ASYNC_COPY_SCOPE:#.*]] = #llvm.alias_scope<id = "amdgpu.AsyncCopies"
#blocked = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [1, 64], warpsPerCTA = [4, 1], order = [1, 0]}>
#shared = #ttg.swizzled_shared<{vec = 1, perPhase = 1, maxPhase = 1, order = [1, 0]}>
#smem = #ttg.shared_memory
module attributes {"ttg.num-ctas" = 1 : i32, "ttg.num-warps" = 4 : i32, ttg.shared = 8192 : i32, ttg.target = "hip:gfx942", "ttg.threads-per-warp" = 64 : i32} {
  tt.func public @buffer_load_to_local_alias(%arg0: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32},
                                             %arg1: !tt.ptr<f16>,
                                             %arg2: tensor<8x64xi32, #blocked>,
                                             %arg3: !ttg.memdesc<8x64xf16, #shared, #smem, mutable>) {
    // COMMON: rocdl.raw.ptr.buffer.load.lds {{.*}} {alias_scopes = [[[ASYNC_COPY_SCOPE]]]
    %65 = amdgpu.buffer_load_to_local %arg1[%arg2] into %arg3 {OpIdx = #amdgpu.OpIdx<1>} : <f16>[tensor<8x64xi32, #blocked>] -> <8x64xf16, #shared, #smem, mutable>
    // COMMON: llvm.return
    tt.return
  }
}

// -----

// COMMON: [[ASYNC_COPY_SCOPE:#.*]] = #llvm.alias_scope<id = "amdgpu.AsyncCopies"
// COMMON: [[LOCAL_LOAD_SCOPE:#.*]] = #llvm.alias_scope<id = "amdgpu.LocalLoads"
#blocked = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [64, 1], warpsPerCTA = [1, 1], order = [0, 1]}>
#shared = #ttg.swizzled_shared<{vec = 8, perPhase = 8, maxPhase = 2, order = [0, 1]}>
#shared1 = #ttg.swizzled_shared<{vec = 8, perPhase = 1, maxPhase = 16, order = [1, 0]}>
#smem = #ttg.shared_memory
#mma = #ttg.amd_mfma<{versionMajor = 4, versionMinor = 0, warpsPerCTA = [1, 4], instrShape = [32, 32], isTransposed = true}>
module attributes {"ttg.num-ctas" = 1 : i32, "ttg.num-warps" = 1 : i32, ttg.target = "hip:gfx950", "ttg.threads-per-warp" = 64 : i32} {
  tt.func public @local_loads_with_token_from_async_wait(%arg0: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32},
                                                         %arg1: !ttg.memdesc<64x1xf16, #shared, #smem, mutable>,
                                                         %arg4: !ttg.memdesc<16x16xf16, #shared, #smem, mutable>) {
    // We need the splat to allow the AxisAnalysis to work during lowering
    %ptr = tt.splat %arg0 : !tt.ptr<f16> -> tensor<64x1x!tt.ptr<f16>, #blocked>

    // COMMON: rocdl.global.load.lds {{.*}} {alias_scopes = [[[ASYNC_COPY_SCOPE]]]
    %0 = ttg.async_copy_global_to_local %ptr, %arg1 : tensor<64x1x!tt.ptr<f16>, #blocked> -> <64x1xf16, #shared, #smem, mutable>
    %1 = ttg.async_commit_group %0

    %3 = ttg.async_wait %1 {num = 1 : i32}

    // Check alias information is added for different lowering paths

    // Test lowering path in common MemoryOpToLLVM pattern
    // COMMON: llvm.load {{.*}} {alias_scopes = [[[LOCAL_LOAD_SCOPE]]], {{.*}}, noalias_scopes = [[[ASYNC_COPY_SCOPE]]]
    %4 = ttg.local_load %arg1 token %3 : !ttg.memdesc<64x1xf16, #shared, #smem, mutable> -> tensor<64x1xf16, #blocked>

    // Test lowering path in AMD's MemoryOpToLLVM pattern
    // GFX942-COUNT-8: llvm.load {{.*}} {alias_scopes = [[[LOCAL_LOAD_SCOPE]]], {{.*}}, noalias_scopes = [[[ASYNC_COPY_SCOPE]]]
    // GFX950-COUNT-2: rocdl.ds.read.tr16.b64 {{.*}} {alias_scopes = [[[LOCAL_LOAD_SCOPE]]], noalias_scopes = [[[ASYNC_COPY_SCOPE]]]
    %5 = ttg.local_load %arg4 token %3 : !ttg.memdesc<16x16xf16, #shared, #smem, mutable> -> tensor<16x16xf16, #ttg.dot_op<{opIdx = 0, parent = #mma, kWidth = 8}>>

    // COMMON: llvm.return
    tt.return
  }
}

// -----

// Same as above but LocalLoad does not use the token from AsyncWait

// COMMON: [[ASYNC_COPY_SCOPE:#.*]] = #llvm.alias_scope<id = "amdgpu.AsyncCopies"
#blocked = #ttg.blocked<{sizePerThread = [1, 1], threadsPerWarp = [64, 1], warpsPerCTA = [1, 1], order = [0, 1]}>
#shared = #ttg.swizzled_shared<{vec = 8, perPhase = 8, maxPhase = 2, order = [0, 1]}>
#shared1 = #ttg.swizzled_shared<{vec = 8, perPhase = 1, maxPhase = 16, order = [1, 0]}>
#smem = #ttg.shared_memory
#mma = #ttg.amd_mfma<{versionMajor = 4, versionMinor = 0, warpsPerCTA = [1, 4], instrShape = [32, 32], isTransposed = true}>
module attributes {"ttg.num-ctas" = 1 : i32, "ttg.num-warps" = 1 : i32, ttg.target = "hip:gfx950", "ttg.threads-per-warp" = 64 : i32} {
  tt.func public @local_loads_without_token_from_async_wait(%arg0: !tt.ptr<f16> {tt.divisibility = 16 : i32, tt.pointer_range = 32 : i32},
                                                            %arg1: !ttg.memdesc<64x1xf16, #shared, #smem, mutable>,
                                                            %arg4: !ttg.memdesc<16x16xf16, #shared, #smem, mutable>) {
    // We need the splat to allow the AxisAnalysis to work during lowering
    %ptr = tt.splat %arg0 : !tt.ptr<f16> -> tensor<64x1x!tt.ptr<f16>, #blocked>

    // COMMON: rocdl.global.load.lds {{.*}} {alias_scopes = [[[ASYNC_COPY_SCOPE]]]
    %0 = ttg.async_copy_global_to_local %ptr, %arg1 : tensor<64x1x!tt.ptr<f16>, #blocked> -> <64x1xf16, #shared, #smem, mutable>
    %1 = ttg.async_commit_group %0

    %3 = ttg.async_wait %1 {num = 1 : i32}

    // Check alias information is not used at all for different lowering paths
    // COMMON-NOT: [[ASYNC_COPY_SCOPE]]

    // Test lowering path in common MemoryOpToLLVM pattern
    %4 = ttg.local_load %arg1 token %0 : !ttg.memdesc<64x1xf16, #shared, #smem, mutable> -> tensor<64x1xf16, #blocked>
    %5 = ttg.local_load %arg1 : !ttg.memdesc<64x1xf16, #shared, #smem, mutable> -> tensor<64x1xf16, #blocked>

    // Test lowering path in AMD's MemoryOpToLLVM pattern
    %7 = ttg.local_load %arg4 token %0 : !ttg.memdesc<16x16xf16, #shared, #smem, mutable> -> tensor<16x16xf16, #ttg.dot_op<{opIdx = 0, parent = #mma, kWidth = 8}>>
    %8 = ttg.local_load %arg4 : !ttg.memdesc<16x16xf16, #shared, #smem, mutable> -> tensor<16x16xf16, #ttg.dot_op<{opIdx = 0, parent = #mma, kWidth = 8}>>

    // COMMON: llvm.return
    tt.return
  }
}
