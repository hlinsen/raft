/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#pragma once

#include <cub/cub.cuh>

#include <raft/cudart_utils.h>
#include <raft/cuda_utils.cuh>
#include <raft/linalg/unary_op.cuh>
#include <raft/mr/device/allocator.hpp>
#include <raft/mr/device/buffer.hpp>

namespace raft {
namespace label {

/**
 * Get unique class labels.
 *
 * The y array is assumed to store class labels. The unique values are selected
 * from this array.
 *
 * \tparam value_t numeric type of the arrays with class labels
 * \param [in] y device array of labels, size [n]
 * \param [in] n number of labels
 * \param [out] y_unique device array of unique labels, unallocated on entry,
 *   on exit it has size [n_unique]
 * \param [out] n_unique number of unique labels
 * \param [in] stream cuda stream
 * \param [in] allocator device allocator
 */
template <typename value_t>
void getUniquelabels(value_t *y, size_t n, value_t **y_unique, int *n_unique,
                     cudaStream_t stream,
                     std::shared_ptr<raft::mr::device::allocator> allocator) {
  raft::mr::device::buffer<value_t> y2(allocator, stream, n);
  raft::mr::device::buffer<value_t> y3(allocator, stream, n);
  raft::mr::device::buffer<int> d_num_selected(allocator, stream, 1);
  size_t bytes = 0;
  size_t bytes2 = 0;

  // Query how much temporary storage we will need for cub operations
  // and allocate it
  cub::DeviceRadixSort::SortKeys(NULL, bytes, y, y2.data(), n);
  cub::DeviceSelect::Unique(NULL, bytes2, y2.data(), y3.data(),
                            d_num_selected.data(), n);
  bytes = max(bytes, bytes2);
  raft::mr::device::buffer<char> cub_storage(allocator, stream, bytes);

  // Select Unique classes
  cub::DeviceRadixSort::SortKeys(cub_storage.data(), bytes, y, y2.data(), n);
  cub::DeviceSelect::Unique(cub_storage.data(), bytes, y2.data(), y3.data(),
                            d_num_selected.data(), n);
  raft::update_host(n_unique, d_num_selected.data(), 1, stream);
  CUDA_CHECK(cudaStreamSynchronize(stream));

  // Copy unique classes to output
  *y_unique =
    (value_t *)allocator->allocate(*n_unique * sizeof(value_t), stream);
  raft::copy(*y_unique, y3.data(), *n_unique, stream);
}

/**
 * Assign one versus rest labels.
 *
 * The output labels will have values +/-1:
 * y_out = (y == y_unique[idx]) ? +1 : -1;
 *
 * The output type currently is set to value_t, but for SVM in principle we are
 * free to choose other type for y_out (it should represent +/-1, and it is used
 * in floating point arithmetics).
 *
 * \param [in] y device array if input labels, size [n]
 * \param [in] n number of labels
 * \param [in] y_unique device array of unique labels, size [n_classes]
 * \param [in] n_classes number of unique labels
 * \param [out] y_out device array of output labels
 * \param [in] idx index of unique label that should be labeled as 1
 * \param [in] stream cuda stream
 */
template <typename value_t>
void getOvrlabels(value_t *y, int n, value_t *y_unique, int n_classes,
                  value_t *y_out, int idx, cudaStream_t stream) {
  ASSERT(idx < n_classes,
         "Parameter idx should not be larger than the number "
         "of classes");
  raft::linalg::unaryOp(
    y_out, y, n,
    [idx, y_unique] __device__(value_t y) {
      return y == y_unique[idx] ? +1 : -1;
    },
    stream);
  CUDA_CHECK(cudaPeekAtLastError());
}

// TODO: add one-versus-one selection: select two classes, relabel them to
// +/-1, return array with the new class labels and corresponding indices.

template <typename Type, int TPB_X, typename Lambda>
__global__ void map_label_kernel(Type *map_ids, size_t N_labels, Type *in,
                                 Type *out, size_t N, Lambda filter_op,
                                 bool zero_based = false) {
  int tid = threadIdx.x + blockIdx.x * TPB_X;
  if (tid < N) {
    if (!filter_op(in[tid])) {
      for (size_t i = 0; i < N_labels; i++) {
        if (in[tid] == map_ids[i]) {
          out[tid] = i + !zero_based;
          break;
        }
      }
    }
  }
}

/**
   * Maps an input array containing a series of numbers into a new array
   * where numbers have been mapped to a monotonically increasing set
   * of labels. This can be useful in machine learning algorithms, for instance,
   * where a given set of labels is not taken from a monotonically increasing
   * set. This can happen if they are filtered or if only a subset of the
   * total labels are used in a dataset. This is also useful in graph algorithms
   * where a set of vertices need to be labeled in a monotonically increasing
   * order.
   * @tparam Type the numeric type of the input and output arrays
   * @tparam Lambda the type of an optional filter function, which determines
   * which items in the array to map.
   * @param out the output monotonic array
   * @param in input label array
   * @param N number of elements in the input array
   * @param stream cuda stream to use
   * @param filter_op an optional function for specifying which values
   * should have monotonically increasing labels applied to them.
   */
template <typename Type, typename Lambda>
void make_monotonic(Type *out, Type *in, size_t N, cudaStream_t stream,
                    Lambda filter_op,
                    std::shared_ptr<raft::mr::device::allocator> allocator,
                    bool zero_based = false) {
  static const size_t TPB_X = 256;

  dim3 blocks(raft::ceildiv(N, TPB_X));
  dim3 threads(TPB_X);

  Type *map_ids;
  int num_clusters;
  getUniquelabels(in, N, &map_ids, &num_clusters, stream, allocator);

  map_label_kernel<Type, TPB_X><<<blocks, threads, 0, stream>>>(
    map_ids, num_clusters, in, out, N, filter_op, zero_based);

  allocator->deallocate(map_ids, num_clusters * sizeof(Type), stream);
}

/**
   * Maps an input array containing a series of numbers into a new array
   * where numbers have been mapped to a monotonically increasing set
   * of labels. This can be useful in machine learning algorithms, for instance,
   * where a given set of labels is not taken from a monotonically increasing
   * set. This can happen if they are filtered or if only a subset of the
   * total labels are used in a dataset. This is also useful in graph algorithms
   * where a set of vertices need to be labeled in a monotonically increasing
   * order.
   * @tparam Type the numeric type of the input and output arrays
   * @tparam Lambda the type of an optional filter function, which determines
   * which items in the array to map.
   * @param out output label array with labels assigned monotonically
   * @param in input label array
   * @param N number of elements in the input array
   * @param stream cuda stream to use
   */
template <typename Type>
void make_monotonic(Type *out, Type *in, size_t N, cudaStream_t stream,
                    std::shared_ptr<raft::mr::device::allocator> allocator,
                    bool zero_based = false) {
  make_monotonic<Type>(
    out, in, N, stream, [] __device__(Type val) { return false; }, allocator,
    zero_based);
}
};  // namespace label
};  // end namespace raft
