/*!
 *  Copyright (c) 2020 by Contributors
 * \file array/cuda/spmm.cu
 * \brief SPMM C APIs and definitions.
 */
#include <dgl/array.h>
#include "./spmm.cuh"
#include "./ge_spmm.cuh"
#include "./functor.cuh"
#include "../../runtime/cuda/cuda_common.h"

namespace dgl {

using namespace cuda;

namespace aten {
namespace {

/*! \brief Call cuBLAS geam API for transpose operation for float and double. */
template <typename DType>
cublasStatus_t Xgeam(cublasHandle_t handle, cublasOperation_t transa,
    cublasOperation_t transb, int m, int n,
    const DType* alpha, const DType* A, int lda,
    const DType* beta, const DType* B, int ldb,
    DType* C, int ldc) {
  LOG(INFO) << "Not supported dtype";
  return CUBLAS_STATUS_EXECUTION_FAILED;
}

template <>
cublasStatus_t Xgeam<float>(cublasHandle_t handle, cublasOperation_t transa,
    cublasOperation_t transb, int m, int n,
    const float* alpha, const float* A, int lda,
    const float* beta, const float* B, int ldb,
    float* C, int ldc) {
  return cublasSgeam(handle, transa, transb, m, n, alpha, A, lda,
      beta, B, ldb, C, ldc);
}

template <>
cublasStatus_t Xgeam<double>(cublasHandle_t handle, cublasOperation_t transa,
    cublasOperation_t transb, int m, int n,
    const double* alpha, const double* A, int lda,
    const double* beta, const double* B, int ldb,
    double* C, int ldc) {
  return cublasDgeam(handle, transa, transb, m, n, alpha, A, lda,
      beta, B, ldb, C, ldc);
}

/* \brief IndexSelect operator kernel implementation.
 * \note duplicate of IndexSelectKernel defined in array_index_select.cu
 */
template <typename DType, typename IdType>
__global__ void _IndexSelectKernel(
    const DType* __restrict__ in,
    const IdType* __restrict__ idx,
    DType* __restrict__ out,
    int n, int m) {
  int i = blockIdx.x;
  for (int j = threadIdx.x; j < m; j += blockDim.x)
    out[i * m + j] = in[idx[i] * m + j];
}

/* \brief Transpose operator kernel implementation.
 * \note not efficient but it's not a bottleneck, used for float16 dtype.
 */
template <typename DType>
__global__ void _TransposeKernel(
    const DType* __restrict__ in,
    DType* __restrict__ out,
    int n, int m) {
  int i = blockIdx.x;
  for (int j = threadIdx.x; j < m; j += blockDim.x)
    out[i * m + j] = in[j * n + i];
}

/*
 * \brief Tranpose the input matrix.
 * \param row number of rows of input matrix.
 * \param col number of columns of input matrix.
 */
template <typename DType>
void _Transpose(const DType* in, DType* out,
                int row, int col) {
  DType alpha = 1., beta = 0.;
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  if (!thr_entry->cublas_handle)
    CUBLAS_CALL(cublasCreate(&(thr_entry->cublas_handle)));
  CUBLAS_CALL(cublasSetStream(thr_entry->cublas_handle, thr_entry->stream));
  CUBLAS_CALL(Xgeam<DType>(
      thr_entry->cublas_handle,
      CUBLAS_OP_T,
      CUBLAS_OP_N,
      row, col,
      &alpha, in, col,
      &beta, nullptr, row,
      out, row));
}

/*
 * \brief Tranpose the input matrix for data type half.
 * \note cuBLAS has no geam API for half data type, fallback to our kernel.
 */
template <>
void _Transpose<half>(const half* in, half* out,
                      int row, int col) {
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  int nt = FindNumThreads(row);
  int nb = col;
  CUDA_KERNEL_CALL(_TransposeKernel, nb, nt, 0, thr_entry->stream, in, out, col, row);
}

/*
 * \brief
 */
template <typename DType, typename IdType>
__global__ void _IndexSelectKernel(const DType* array, const IdType* index,
                                   int64_t length, DType* out) {
  int tx = blockIdx.x * blockDim.x + threadIdx.x;
  int stride_x = gridDim.x * blockDim.x;
  while (tx < length) {
    out[tx] = array[index[tx]];
    tx += stride_x;
  }
}

/* \brief IndexSelect operator.
 * \note duplicate of IndexSelect defined in array_op.h but it can
 *    not be applied to float16 dtype.
 */
template<typename DType, typename IdType>
NDArray _IndexSelect(NDArray array, NDArray index) {
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  const DType* array_data = static_cast<DType*>(array->data);
  const IdType* idx_data = static_cast<IdType*>(index->data);
  const int64_t arr_len = array->shape[0];
  const int64_t len = index->shape[0];
  NDArray ret = NDArray::Empty({len}, array->dtype, array->ctx);
  if (len == 0)
    return ret;
  DType* ret_data = static_cast<DType*>(ret->data);
  const int nt = FindNumThreads(len);
  const int nb = (len + nt - 1) / nt;
  CUDA_KERNEL_CALL(_IndexSelectKernel, nb, nt, 0, thr_entry->stream,
      array_data, idx_data, len, ret_data);
  return ret;
}

}  // namespace

namespace cusparse {

#if CUDART_VERSION < 11000
template <typename DType>
cusparseStatus_t Xcsrmm2(cusparseHandle_t handle, cusparseOperation_t transA,
    cusparseOperation_t transB, int m, int n, int k, int nnz,
    const DType* alpha, const cusparseMatDescr_t descrA,
    const DType* csrValA, const int* csrRowPtrA, const int* csrColIndA,
    const DType* B, int ldb, const DType* beta, DType* C, int ldc) {
  LOG(INFO) << "Not supported dtype";
  return CUSPARSE_STATUS_EXECUTION_FAILED;
}

template <>
cusparseStatus_t Xcsrmm2<float>(cusparseHandle_t handle, cusparseOperation_t transA,
    cusparseOperation_t transB, int m, int n, int k, int nnz,
    const float* alpha, const cusparseMatDescr_t descrA,
    const float* csrValA, const int* csrRowPtrA, const int* csrColIndA,
    const float* B, int ldb, const float* beta, float* C, int ldc) {
  return cusparseScsrmm2(handle, transA, transB, m, n, k, nnz,
      alpha, descrA, csrValA, csrRowPtrA, csrColIndA,
      B, ldb, beta, C, ldc);
}

template <>
cusparseStatus_t Xcsrmm2<double>(cusparseHandle_t handle, cusparseOperation_t transA,
    cusparseOperation_t transB, int m, int n, int k, int nnz,
    const double* alpha, const cusparseMatDescr_t descrA,
    const double* csrValA, const int* csrRowPtrA, const int* csrColIndA,
    const double* B, int ldb, const double* beta, double* C, int ldc) {
  return cusparseDcsrmm2(handle, transA, transB, m, n, k, nnz,
      alpha, descrA, csrValA, csrRowPtrA, csrColIndA,
      B, ldb, beta, C, ldc);
}
#endif

/*! Cusparse implementation of SpMM on Csr format. */
template <typename DType, typename IdType>
void CusparseCsrmm2(
    const DLContext& ctx,
    const CSRMatrix& csr,
    const DType* B_data, const DType* A_data,
    DType* C_data,
    int x_length) {
  // We use csrmm2 to perform following operation:
  // C = A x B, where A is a sparse matrix in csr format, B is the dense matrix for node
  // feature tensor. However, since cusparse only supports column-major, while our tensor
  // is stored in row-major, the actual computation is:
  // C = trans(A x trans(B)).
  // Currently, we use cublasXgeam to implement transposition and allocate intermediate
  // workspace memory for this.
  const int m = csr.num_rows;
  const int n = x_length;
  const int k = csr.num_cols;
  const int nnz = csr.indices->shape[0];
  const DType alpha = 1.0;
  const DType beta = 0.0;
  // device
  auto device = runtime::DeviceAPI::Get(ctx);
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  // allocate cusparse handle if needed
  if (!thr_entry->cusparse_handle) {
    CUSPARSE_CALL(cusparseCreate(&(thr_entry->cusparse_handle)));
  }
  CUSPARSE_CALL(cusparseSetStream(thr_entry->cusparse_handle, thr_entry->stream));
  // all one data array
  DType* valptr = nullptr;
  if (!A_data) {
    valptr = static_cast<DType*>(device->AllocWorkspace(ctx, nnz * sizeof(DType)));
    _Fill(valptr, nnz, static_cast<DType>(1.));
  }
#if CUDART_VERSION >= 11000
  cusparseSpMatDescr_t matA;
  cusparseDnMatDescr_t matB, matC;
  constexpr auto dtype = cuda_dtype<DType>::value;
  constexpr auto idtype = cusparse_idtype<IdType>::value;
  CUSPARSE_CALL(cusparseCreateCsr(&matA,
      m, k, nnz,
      static_cast<IdType*>(csr.indptr->data),
      static_cast<IdType*>(csr.indices->data),
      const_cast<DType*>(valptr? valptr : A_data),
      idtype, idtype,
      CUSPARSE_INDEX_BASE_ZERO, dtype));
  CUSPARSE_CALL(cusparseCreateDnMat(&matB,
      k, n, n,
      const_cast<DType*>(B_data), dtype, CUSPARSE_ORDER_ROW));
  CUSPARSE_CALL(cusparseCreateDnMat(&matC,
      m, n, n,
      C_data, dtype, CUSPARSE_ORDER_ROW));

  auto transA = CUSPARSE_OPERATION_NON_TRANSPOSE;
  auto transB = CUSPARSE_OPERATION_NON_TRANSPOSE;
  size_t workspace_size;
  CUSPARSE_CALL(cusparseSpMM_bufferSize(
      thr_entry->cusparse_handle, transA, transB,
      &alpha, matA, matB, &beta, matC,
      dtype, CUSPARSE_SPMM_CSR_ALG2,
      &workspace_size));
  void* workspace = device->AllocWorkspace(ctx, workspace_size);
  CUSPARSE_CALL(cusparseSpMM(
      thr_entry->cusparse_handle, transA, transB,
      &alpha, matA, matB, &beta, matC,
      dtype, CUSPARSE_SPMM_CSR_ALG2,
      workspace));
  device->FreeWorkspace(ctx, workspace);

  CUSPARSE_CALL(cusparseDestroySpMat(matA));
  CUSPARSE_CALL(cusparseDestroyDnMat(matB));
  CUSPARSE_CALL(cusparseDestroyDnMat(matC));
#else
  // allocate matrix for temporary transposed output
  DType* trans_out = static_cast<DType*>(device->AllocWorkspace(ctx, m * n * sizeof(DType)));

  cusparseMatDescr_t descr;
  CUSPARSE_CALL(cusparseCreateMatDescr(&descr));
  CUSPARSE_CALL(cusparseSetMatType(descr, CUSPARSE_MATRIX_TYPE_GENERAL));
  CUSPARSE_CALL(cusparseSetMatIndexBase(descr, CUSPARSE_INDEX_BASE_ZERO));
  CUSPARSE_CALL(Xcsrmm2<DType>(
      thr_entry->cusparse_handle,
      CUSPARSE_OPERATION_NON_TRANSPOSE,
      CUSPARSE_OPERATION_TRANSPOSE,
      m, n, k, nnz, &alpha,
      descr, (valptr)? valptr : A_data,
      static_cast<int32_t*>(csr.indptr->data),
      static_cast<int32_t*>(csr.indices->data),
      B_data, n, &beta, trans_out, m));
  CUSPARSE_CALL(cusparseDestroyMatDescr(descr));
  // transpose the output matrix
  _Transpose(trans_out, C_data, n, m);
  device->FreeWorkspace(ctx, trans_out);
#endif
  if (valptr)
    device->FreeWorkspace(ctx, valptr);
}

/*! Cusparse implementation of SpMM on Csr format. */
template <typename DType, typename IdType>
void CusparseCsrmm2Hetero(
    const DLContext& ctx,
    const CSRMatrix& csr,
    const DType* B_data, const DType* A_data,
    DType* C_data,
    int64_t x_length,
    cudaStream_t strm_id) {
  // We use csrmm2 to perform following operation:
  // C = A x B, where A is a sparse matrix in csr format, B is the dense matrix for node
  // feature tensor. However, since cusparse only supports column-major, while our tensor
  // is stored in row-major, the actual computation is:
  // C = trans(A x trans(B)).
  // Currently, we use cublasXgeam to implement transposition and allocate intermediate
  // workspace memory for this.
  int int_maxlimit = std::numeric_limits<int>::max();
  CHECK_GE(int_maxlimit, (csr.num_rows));
  CHECK_GE(int_maxlimit, csr.num_cols);
  CHECK_GE(int_maxlimit, csr.indices->shape[0]);
  const int m = csr.num_rows;
  const int n = x_length;
  const int k = csr.num_cols;
  const int nnz = csr.indices->shape[0];
  const DType alpha = 1.0;
  const DType beta = 1.0;
  // device
  auto device = runtime::DeviceAPI::Get(ctx);
  auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
  // allocate cusparse handle if needed
  if (!thr_entry->cusparse_handle) {
    CUSPARSE_CALL(cusparseCreate(&(thr_entry->cusparse_handle)));
  }
  CUSPARSE_CALL(cusparseSetStream(thr_entry->cusparse_handle, strm_id));
  // all one data array
  DType* valptr = nullptr;
  if (!A_data) {
    valptr = static_cast<DType*>(device->AllocWorkspace(ctx, nnz * sizeof(DType)));
    _Fill(valptr, nnz, static_cast<DType>(1.));
  }
#if CUDART_VERSION >= 11000
  cusparseSpMatDescr_t matA;
  cusparseDnMatDescr_t matB, matC;
  constexpr auto dtype = cuda_dtype<DType>::value;
  constexpr auto idtype = cusparse_idtype<IdType>::value;
  CUSPARSE_CALL(cusparseCreateCsr(&matA,
      m, k, nnz,
      static_cast<IdType*>(csr.indptr->data),
      static_cast<IdType*>(csr.indices->data),
      const_cast<DType*>(valptr? valptr : A_data),
      idtype, idtype,
      CUSPARSE_INDEX_BASE_ZERO, dtype));
  CUSPARSE_CALL(cusparseCreateDnMat(&matB,
      k, n, n,
      const_cast<DType*>(B_data), dtype, CUSPARSE_ORDER_ROW));
  CUSPARSE_CALL(cusparseCreateDnMat(&matC,
      m, n, n,
      C_data, dtype, CUSPARSE_ORDER_ROW));

  auto transA = CUSPARSE_OPERATION_NON_TRANSPOSE;
  auto transB = CUSPARSE_OPERATION_NON_TRANSPOSE;
  size_t workspace_size;
  CUSPARSE_CALL(cusparseSpMM_bufferSize(
      thr_entry->cusparse_handle, transA, transB,
      &alpha, matA, matB, &beta, matC,
      dtype, CUSPARSE_SPMM_CSR_ALG2,
      &workspace_size));
  void* workspace = device->AllocWorkspace(ctx, workspace_size);
  CUSPARSE_CALL(cusparseSpMM(
      thr_entry->cusparse_handle, transA, transB,
      &alpha, matA, matB, &beta, matC,
      dtype, CUSPARSE_SPMM_CSR_ALG2,
      workspace));
  device->FreeWorkspace(ctx, workspace);

  CUSPARSE_CALL(cusparseDestroySpMat(matA));
  CUSPARSE_CALL(cusparseDestroyDnMat(matB));
  CUSPARSE_CALL(cusparseDestroyDnMat(matC));
#else
  cusparseMatDescr_t descr;
  CUSPARSE_CALL(cusparseCreateMatDescr(&descr));
  CUSPARSE_CALL(cusparseSetMatType(descr, CUSPARSE_MATRIX_TYPE_GENERAL));
  CUSPARSE_CALL(cusparseSetMatIndexBase(descr, CUSPARSE_INDEX_BASE_ZERO));
  CHECK_EQ(sizeof(IdType), sizeof(int32_t));
  CUSPARSE_CALL(Xcsrmm2<DType>(
      thr_entry->cusparse_handle,
      CUSPARSE_OPERATION_NON_TRANSPOSE,
      CUSPARSE_OPERATION_TRANSPOSE,
      m, n, k, nnz, &alpha,
      descr, (valptr)? valptr : A_data,
      static_cast<int32_t*>(csr.indptr->data),
      static_cast<int32_t*>(csr.indices->data),
      B_data, n, &beta, C_data, m));
  CUSPARSE_CALL(cusparseDestroyMatDescr(descr));
#endif
  if (valptr)
    device->FreeWorkspace(ctx, valptr);
}

}  // namespace cusparse

#define SWITCH_OP(op, Op, ...)                                      \
  do {                                                              \
    if ((op) == "add") {                                            \
      typedef cuda::binary::Add<DType> Op;                          \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "sub") {                                     \
      typedef cuda::binary::Sub<DType> Op;                          \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "mul") {                                     \
      typedef cuda::binary::Mul<DType> Op;                          \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "div") {                                     \
      typedef cuda::binary::Div<DType> Op;                          \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "copy_lhs") {                                \
      typedef cuda::binary::CopyLhs<DType> Op;                      \
      { __VA_ARGS__ }                                               \
    } else if ((op) == "copy_rhs") {                                \
      typedef cuda::binary::CopyRhs<DType> Op;                      \
      { __VA_ARGS__ }                                               \
    } else {                                                        \
      LOG(FATAL) << "Unsupported SpMM binary operator: " << op;     \
    }                                                               \
  } while (0)

/*!
 * \brief Determine whether cusparse SpMM function is applicable.
 */
template <int bits, typename IdType>
inline bool cusparse_available(bool more_nnz_than_matrix_size) {
#if CUDART_VERSION < 11000
  if (std::is_same<IdType, int>::value)
    if (bits > 16)
      return true;
  return false;
#else
  if (bits == 16)
    return false;  // cusparse's SpMM on fp16 is slow, temporally disabled.
  // If the CSR matrix has more NNZ than matrix size, we should not use cuSPARSE 11.1.
  return !more_nnz_than_matrix_size;
#endif
}

/*!
 * \brief CUDA implementation of g-SpMM on Csr format.
 * \note use cusparse if the reduce operator is `sum` and there is
 *       no broadcast, use dgl's kernel in other cases.
 */
template <int XPU, typename IdType, int bits>
void SpMMCsr(const std::string& op, const std::string& reduce,
             const BcastOff& bcast,
             const CSRMatrix& csr,
             NDArray ufeat,
             NDArray efeat,
             NDArray out,
             std::vector<NDArray> out_aux) {
  int64_t feat_len = bcast.out_len;
  bool is_scalar_efeat = efeat.NumElements() == csr.indices->shape[0];
  bool use_efeat = op != "copy_lhs";

  if (reduce == "sum") {
    bool more_nnz = (csr.indices->shape[0] > csr.num_rows * csr.num_cols);
    if (op == "copy_lhs" && cusparse_available<bits, IdType>(more_nnz)) {
      // cusparse
      int64_t x_length = 1;
      for (int i = 1; i < ufeat->ndim; ++i)
        x_length *= ufeat->shape[i];
      SWITCH_BITS(bits, DType, {
        cusparse::CusparseCsrmm2<DType, IdType>(
            ufeat->ctx, csr,
            static_cast<DType*>(ufeat->data),
            nullptr,
            static_cast<DType*>(out->data),
            x_length);
      });
    } else if (op == "mul" && is_scalar_efeat && cusparse_available<bits, IdType>(more_nnz)) {
      // cusparse
      int64_t x_length = 1;
      for (int i = 1; i < ufeat->ndim; ++i)
        x_length *= ufeat->shape[i];
      if (!IsNullArray(csr.data)) {
        SWITCH_BITS(bits, DType, {
          efeat = _IndexSelect<DType, IdType>(efeat, csr.data);
        });
      }
      SWITCH_BITS(bits, DType, {
        cusparse::CusparseCsrmm2<DType, IdType>(
            ufeat->ctx, csr,
            static_cast<DType*>(ufeat->data),
            static_cast<DType*>(efeat->data),
            static_cast<DType*>(out->data),
            x_length);
      });
    } else {  // general kernel
      SWITCH_BITS(bits, DType, {
        SWITCH_OP(op, Op, {
          cuda::SpMMCsr<IdType, DType, Op, cuda::reduce::Sum<IdType, DType> >(
              bcast, csr, ufeat, efeat, out, NullArray(), NullArray());
        });
      });
    }
  } else if (reduce == "max") {
    SWITCH_BITS(bits, DType, {
      SWITCH_OP(op, Op, {
        cuda::SpMMCsr<IdType, DType, Op, cuda::reduce::Max<IdType, DType> >(
            bcast, csr, ufeat, efeat, out, out_aux[0], out_aux[1]);
      });
    });
  } else if (reduce == "min") {
    SWITCH_BITS(bits, DType, {
      SWITCH_OP(op, Op, {
        cuda::SpMMCsr<IdType, DType, Op, cuda::reduce::Min<IdType, DType> >(
            bcast, csr, ufeat, efeat, out, out_aux[0], out_aux[1]);
      });
    });
  } else {
    LOG(FATAL) << "Not implemented";
  }
}

/*!
 * \brief CUDA implementation of g-SpMM on Csr format.
 * \note use cusparse if the reduce operator is `sum` and there is
 *       no broadcast, use dgl's kernel in other cases.
 */
template <int XPU, typename IdType, int bits>
void SpMMCsrHetero(const std::string& op, const std::string& reduce,
             const BcastOff& bcast,
             const std::vector<CSRMatrix>& vec_csr,
             const std::vector<NDArray>& vec_ufeat,
             const std::vector<NDArray>& vec_efeat,
             std::vector<NDArray> vec_out,
             const std::vector<NDArray>& out_aux,
             const std::vector<dgl_type_t>& ufeat_ntids,  // ufeat node type id
             const std::vector<dgl_type_t>& out_ntids) {  // output node type id
  bool is_scalar_efeat = vec_efeat[0].NumElements() == vec_csr[0].indices->shape[0];
  bool use_efeat = op != "copy_lhs";
  auto device = runtime::DeviceAPI::Get(vec_csr[0].indptr->ctx);
  SWITCH_BITS(bits, DType, {
    std::vector<DType*> trans_out(vec_out.size(), NULL);

    bool use_legacy_cusparsemm =
        (CUDART_VERSION < 11000) &&
        // legacy cuSPARSE does not care about NNZ, hence the argument "false".
        ((op == "copy_lhs" && cusparse_available<bits, IdType>(false)) ||
         (op == "mul" && is_scalar_efeat && cusparse_available<bits, IdType>(false)));
    // Create temporary output buffer to store non-transposed output
    if (use_legacy_cusparsemm) {
      for (dgl_type_t ntype = 0; ntype < vec_out.size(); ++ntype) {
        const int m = vec_out[ntype]->shape[0];
        const int n = vec_out[ntype]->shape[1];
        if (m == 0) continue;
        DType *out = static_cast<DType*>(device->AllocWorkspace(vec_csr[0].indptr->ctx,
          m * n * sizeof(DType)));
        CUDA_CALL(cudaMemset(out, 0, m * n * sizeof(DType)));
        trans_out[ntype] = out;
      }
    }

    // Check shape of ufeat for all relation type and compute feature size
    int64_t x_length = 1;
    for (dgl_type_t etype = 0; etype < (ufeat_ntids.size() - 1); ++etype) {
      NDArray ufeat = vec_ufeat[ufeat_ntids[etype]];
      NDArray next_ufeat = vec_ufeat[ufeat_ntids[etype + 1]];
      CHECK_EQ(ufeat->ndim, next_ufeat->ndim) << "Input features have different shapes";
      for (int i = 1; i < ufeat->ndim; ++i) {
        if (ufeat->shape[i] != next_ufeat->shape[i]) {
          if (ufeat->shape[i] == 1 || next_ufeat->shape[i] == 1)
            LOG(FATAL) <<
              "Homogenized message passing on heterogeneous graphs does not support " <<
              "automatic broadcasting.  Please manually broadcast it before calling " <<
              "message passing functions.";
          else
            LOG(FATAL) << "Input features have different shapes.";
          return;
        }

        if (etype == 0)
          x_length *= ufeat->shape[i];
      }
    }

    auto* thr_entry = runtime::CUDAThreadEntry::ThreadLocal();
    for (dgl_type_t etype = 0; etype < ufeat_ntids.size(); ++etype) {
      const dgl_type_t src_id = ufeat_ntids[etype];
      const dgl_type_t dst_id = out_ntids[etype];
      CSRMatrix csr = vec_csr[etype];
      if (reduce == "sum") {
        bool more_nnz = (csr.indices->shape[0] > csr.num_rows * csr.num_cols);
          /* Call  SpMM for each relation type */
        if (op == "copy_lhs" && cusparse_available<bits, IdType>(more_nnz)) {  // cusparse
          /* If CUDA is less than 11.0, put the output in trans_out for later transposition */
          DType *out = (CUDART_VERSION < 11000) ? trans_out[dst_id] :
            static_cast<DType*>(vec_out[dst_id]->data);
          cusparse::CusparseCsrmm2Hetero<DType, IdType>(
              csr.indptr->ctx, csr,
              static_cast<DType*>(vec_ufeat[src_id]->data),
              nullptr,
              out,
              x_length, thr_entry->stream);
        } else if (op == "mul" && is_scalar_efeat &&
            cusparse_available<bits, IdType>(more_nnz)) {  // cusparse
          NDArray efeat = vec_efeat[etype];
          if (!IsNullArray(csr.data))
            efeat = _IndexSelect<DType, IdType>(efeat, csr.data);
          cusparse::CusparseCsrmm2Hetero<DType, IdType>(
              csr.indptr->ctx, csr,
              static_cast<DType*>(vec_ufeat[src_id]->data),
              static_cast<DType*>(efeat->data),
              // TODO(Israt): Change vec_out to trans_out to support CUDA version < 11
              static_cast<DType*>(vec_out[dst_id]->data),
              x_length, thr_entry->stream);
        } else {  // general kernel
          NDArray ufeat = (vec_ufeat.size() == 0) ?
            NullArray() : vec_ufeat[src_id];
          NDArray efeat = (vec_efeat.size() == 0) ?
            NullArray() : vec_efeat[etype];
          SWITCH_OP(op, Op, {
            cuda::SpMMCsr<IdType, DType, Op, cuda::reduce::Sum<IdType, DType> >(
                bcast, csr, ufeat, efeat, vec_out[dst_id], NullArray(), NullArray());
          });
        }
      } else if (reduce == "max") {
          SWITCH_OP(op, Op, {
            NDArray ufeat = (vec_ufeat.size() == 0) ?
                NullArray() : vec_ufeat[src_id];
            NDArray efeat = (vec_efeat.size() == 0) ?
                NullArray() : vec_efeat[etype];
            cuda::SpMMCsr<IdType, DType, Op, cuda::reduce::Max<IdType, DType> >(
                bcast, csr, ufeat, efeat, vec_out[dst_id], out_aux[0], out_aux[1]);
          });
      } else if (reduce == "min") {
          SWITCH_OP(op, Op, {
            NDArray ufeat = (vec_ufeat.size() == 0) ?
                NullArray() : vec_ufeat[src_id];
            NDArray efeat = (vec_efeat.size() == 0) ?
                NullArray() : vec_efeat[etype];
            cuda::SpMMCsr<IdType, DType, Op, cuda::reduce::Min<IdType, DType> >(
                bcast, csr, ufeat, efeat, vec_out[dst_id], out_aux[0], out_aux[1]);
        });
      } else {
        LOG(FATAL) << "Not implemented";
      }
    }

    if (use_legacy_cusparsemm) {
      // transpose output
      for (dgl_type_t ntype = 0; ntype < vec_out.size(); ++ntype) {
        const int m = vec_out[ntype]->shape[0];
        const int n = vec_out[ntype]->shape[1];
        if (m == 0) continue;
        DType *C_data = static_cast<DType*>(vec_out[ntype]->data);
        _Transpose(trans_out[ntype], C_data, n, m);
        device->FreeWorkspace(vec_csr[0].indptr->ctx, trans_out[ntype]);
      }
    }
  });
}

/*!
 * \brief CUDA implementation of g-SpMM on Coo format.
 */
template <int XPU, typename IdType, int bits>
void SpMMCoo(const std::string& op, const std::string& reduce,
             const BcastOff& bcast,
             const COOMatrix& coo,
             NDArray ufeat,
             NDArray efeat,
             NDArray out,
             std::vector<NDArray> out_aux) {
  if (reduce == "sum") {
    SWITCH_BITS(bits, DType, {
      SWITCH_OP(op, Op, {
        cuda::SpMMCoo<IdType, DType, Op, cuda::reduce::Sum<IdType, DType, true> > (
            bcast, coo, ufeat, efeat, out, NullArray(), NullArray());
      });
    });
  } else if (reduce == "max") {
    SWITCH_BITS(bits, DType, {
      SWITCH_OP(op, Op, {
        cuda::SpMMCoo<IdType, DType, Op, cuda::reduce::Max<IdType, DType, true> > (
            bcast, coo, ufeat, efeat, out, out_aux[0], out_aux[1]);
      });
    });
  }  else if (reduce == "min") {
    SWITCH_BITS(bits, DType, {
      SWITCH_OP(op, Op, {
        cuda::SpMMCoo<IdType, DType, Op, cuda::reduce::Min<IdType, DType, true> > (
            bcast, coo, ufeat, efeat, out, out_aux[0], out_aux[1]);
      });
    });
  } else {
    LOG(FATAL) << "Not implemented";
  }
}

template void SpMMCsr<kDLGPU, int32_t, 16>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCsr<kDLGPU, int64_t, 16>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCsr<kDLGPU, int32_t, 32>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCsr<kDLGPU, int64_t, 32>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCsr<kDLGPU, int32_t, 64>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCsr<kDLGPU, int64_t, 64>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const CSRMatrix& csr,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);

template void SpMMCsrHetero<kDLGPU, int32_t, 16>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const std::vector<CSRMatrix>& csr,
    const std::vector<NDArray>& ufeat, const std::vector<NDArray>& efeat,
    std::vector<NDArray> out, const std::vector<NDArray>& out_aux,
    const std::vector<dgl_type_t>& ufeat_ntids, const std::vector<dgl_type_t>& out_ntids);
template void SpMMCsrHetero<kDLGPU, int64_t, 16>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const std::vector<CSRMatrix>& csr,
    const std::vector<NDArray>& ufeat, const std::vector<NDArray>& efeat,
    std::vector<NDArray> out, const std::vector<NDArray>& out_aux,
    const std::vector<dgl_type_t>& ufeat_ntids, const std::vector<dgl_type_t>& out_ntids);
template void SpMMCsrHetero<kDLGPU, int32_t, 32>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const std::vector<CSRMatrix>& csr,
    const std::vector<NDArray>& ufeat, const std::vector<NDArray>& efeat,
    std::vector<NDArray> out, const std::vector<NDArray>& out_aux,
    const std::vector<dgl_type_t>& ufeat_ntids, const std::vector<dgl_type_t>& out_ntids);
template void SpMMCsrHetero<kDLGPU, int64_t, 32>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const std::vector<CSRMatrix>& csr,
    const std::vector<NDArray>& ufeat, const std::vector<NDArray>& efeat,
    std::vector<NDArray> out, const std::vector<NDArray>& out_aux,
    const std::vector<dgl_type_t>& ufeat_ntids, const std::vector<dgl_type_t>& out_ntids);
template void SpMMCsrHetero<kDLGPU, int32_t, 64>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const std::vector<CSRMatrix>& csr,
    const std::vector<NDArray>& ufeat, const std::vector<NDArray>& efeat,
    std::vector<NDArray> out, const std::vector<NDArray>& out_aux,
    const std::vector<dgl_type_t>& ufeat_ntids, const std::vector<dgl_type_t>& out_ntids);
template void SpMMCsrHetero<kDLGPU, int64_t, 64>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const std::vector<CSRMatrix>& csr,
    const std::vector<NDArray>& ufeat, const std::vector<NDArray>& efeat,
    std::vector<NDArray> out, const std::vector<NDArray>& out_aux,
    const std::vector<dgl_type_t>& ufeat_ntids, const std::vector<dgl_type_t>& out_ntids);

template void SpMMCoo<kDLGPU, int32_t, 16>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCoo<kDLGPU, int64_t, 16>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCoo<kDLGPU, int32_t, 32>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCoo<kDLGPU, int64_t, 32>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCoo<kDLGPU, int32_t, 64>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);
template void SpMMCoo<kDLGPU, int64_t, 64>(
    const std::string& op, const std::string& reduce,
    const BcastOff& bcast, const COOMatrix& coo,
    NDArray ufeat, NDArray efeat, NDArray out, std::vector<NDArray> out_aux);


}  // namespace aten
}  // namespace dgl
