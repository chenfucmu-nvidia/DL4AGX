// Copyright (c) OpenMMLab. All rights reserved
#include <assert.h>
#include <cuda_fp16.h>

#include "ms_deform_attn_kernel.cuh"
#include "ms_deform_attn_kernel.hpp"
#include "ms_deform_attn.h"

template <typename scalar_t>
void ms_deformable_im2col_cuda(cudaStream_t stream, scalar_t const* dataValue,
                               int32_t const* dataSpatialShapes, int32_t const* dataLevelStartIndex,
                               scalar_t const* dataSamplingLoc, scalar_t const* dataAttnWeight,
                               int32_t const batchSize, int32_t const spatialSize,
                               int32_t const numHeads, int32_t const channels,
                               int32_t const numLevels, int32_t const numQuery,
                               int32_t const numPoint, scalar_t* dataCol) {
  int32_t const numKernels = batchSize * numQuery * numHeads * channels;
  int32_t const numActualKernels = batchSize * numQuery * numHeads * channels;

  ms_deformable_im2col_gpu_kernel<scalar_t>
      <<<GET_BLOCKS(numActualKernels), THREADS_PER_BLOCK, 0, stream>>>(
          numKernels, dataValue, dataSpatialShapes, dataLevelStartIndex, dataSamplingLoc,
          dataAttnWeight, batchSize, spatialSize, numHeads, channels, numLevels, numQuery, numPoint,
          dataCol);
}

template <typename scalar_t>
int32_t ms_deform_attn_cuda_forward(const scalar_t* value, const int32_t* spatialShapes,
                                    const int32_t* levelStartIndex, const scalar_t* samplingLoc,
                                    const scalar_t* attnWeight, scalar_t* output, int32_t batch,
                                    int32_t mSpatialSize, int32_t mNumHeads, int32_t mChannels,
                                    int32_t mNumLevels, int32_t mNumQuery, int32_t mNumPoint,
                                    cudaStream_t stream) {
  auto perValueSize = mSpatialSize * mNumHeads * mChannels;
  auto perSampleLocSize = mNumQuery * mNumHeads * mNumLevels * mNumPoint * 2;
  auto perAttnWeightSize = mNumQuery * mNumHeads * mNumLevels * mNumPoint;
  auto perOutputSize = mNumQuery * mNumHeads * mChannels;

  int32_t mIm2colStep = batch;

  for (int32_t n = 0; n < batch / mIm2colStep; ++n) {
    auto columns = output + n * mIm2colStep * perOutputSize;
    ms_deformable_im2col_cuda<scalar_t>(
        stream, value + n * mIm2colStep * perValueSize, spatialShapes, levelStartIndex,
        samplingLoc + n * mIm2colStep * perSampleLocSize,
        attnWeight + n * mIm2colStep * perAttnWeightSize, mIm2colStep, mSpatialSize, mNumHeads,
        mChannels, mNumLevels, mNumQuery, mNumPoint, columns);
  }

  return 0;
}

template int32_t ms_deform_attn_cuda_forward<float>(
    const float* value, const int32_t* spatialShapes, const int32_t* levelStartIndex,
    const float* samplingLoc, const float* attnWeight, float* output, int32_t batch,
    int32_t mSpatialSize, int32_t mNumHeads, int32_t mChannels, int32_t mNumLevels,
    int32_t mNumQuery, int32_t mNumPoint, cudaStream_t stream);

template int32_t ms_deform_attn_cuda_forward<__half>(
    const __half* value, const int32_t* spatialShapes, const int32_t* levelStartIndex,
    const __half* samplingLoc, const __half* attnWeight, __half* output, int32_t batch,
    int32_t mSpatialSize, int32_t mNumHeads, int32_t mChannels, int32_t mNumLevels,
    int32_t mNumQuery, int32_t mNumPoint, cudaStream_t stream);

using namespace nvinfer1;
using nvinfer1::plugin::MultiScaleDeformableAttentionPlugin;

int32_t MultiScaleDeformableAttentionPlugin::enqueue(
  const nvinfer1::PluginTensorDesc *inputDesc,
  const nvinfer1::PluginTensorDesc *outputDesc,
  const void *const *inputs, void *const *outputs,
  void *workSpace,
  cudaStream_t stream
) noexcept {
  int32_t const batch = inputDesc[0].dims.d[0];
  int32_t spatial_size = inputDesc[0].dims.d[1];
  int32_t num_heads = inputDesc[0].dims.d[2];
  int32_t channels = inputDesc[0].dims.d[3];
  int32_t num_levels = inputDesc[1].dims.d[0];
  int32_t num_query = inputDesc[3].dims.d[1];
  int32_t num_point = inputDesc[3].dims.d[4];
  int32_t rc = 0;
  if (inputDesc[0].type == nvinfer1::DataType::kFLOAT) {
    float const *value = static_cast<float const *>(inputs[0]);
    int32_t const *spatialShapes = static_cast<int32_t const *>(inputs[1]);
    int32_t const *levelStartIndex = static_cast<int32_t const *>(inputs[2]);
    float const *samplingLoc = static_cast<float const *>(inputs[3]);
    float const *attnWeight = static_cast<float const *>(inputs[4]);
    float *output = static_cast<float *>(outputs[0]);

    rc = ms_deform_attn_cuda_forward(value, spatialShapes, levelStartIndex, samplingLoc, attnWeight,
                                     output, batch, spatial_size, num_heads, channels, num_levels,
                                     num_query, num_point, stream);
  } else if (inputDesc[0].type == nvinfer1::DataType::kHALF) {
    const __half *value = static_cast<const __half *>(inputs[0]);
    int32_t const *spatialShapes = static_cast<int32_t const *>(inputs[1]);
    int32_t const *levelStartIndex = static_cast<int32_t const *>(inputs[2]);
    const __half *samplingLoc = static_cast<const __half *>(inputs[3]);
    const __half *attnWeight = static_cast<const __half *>(inputs[4]);
    __half *output = static_cast<__half *>(outputs[0]);

    rc = ms_deform_attn_cuda_forward(value, spatialShapes, levelStartIndex, samplingLoc, attnWeight,
                                     output, batch, spatial_size, num_heads, channels, num_levels,
                                     num_query, num_point, stream);
  }

  return rc;
}
