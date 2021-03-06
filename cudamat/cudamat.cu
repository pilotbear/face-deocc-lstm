/*
Copyright (c) 2009,2010, Volodymyr Mnih
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that 
the following conditions are met:

    * Redistributions of source code must retain the above copyright notice, this list of conditions and the 
following disclaimer.
    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and 
the following disclaimer in the documentation and/or other materials provided with the distribution.
    * Neither the name of the <ORGANIZATION> nor the names of its contributors may be used to endorse or 
promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED 
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A 
PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY 
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, 
PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER 
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR 
OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH 
DAMAGE.
*/
#include <stdio.h>
#include <stdlib.h>
#include <cublas.h>
#include <math.h>
#include "rnd_multipliers_32bit.h"
#include "cudamat_kernels.cuh"

#ifdef __cplusplus
extern "C" {
#endif

#include "cudamat.cuh"

/* ------------------------------ CUBLAS init/shutdown ------------------------------ */

inline bool check_cublas_error() {
    cublasStatus status = cublasGetError();
    return status != CUBLAS_STATUS_SUCCESS;
}
inline bool checkCUDAError() {
    cudaError_t err = cudaGetLastError();

    if (cudaSuccess != err)
        printf("%s\n", cudaGetErrorString( err));
    return cudaSuccess != err;
}

const char* get_last_cuda_error() {
    cudaError_t err = cudaGetLastError();

    return cudaGetErrorString( err);
}

int cublas_init() {
    cublasInit();
    if (check_cublas_error())
        return CUBLAS_ERROR;
    else
        return 0;
}

int cublas_shutdown() {
    cublasShutdown();
    cudaThreadExit();
    return 0;
}

int cuda_record_event(cudaEvent_t* t) {
  cudaError_t err = cudaEventRecord(*t, 0);
  if (cudaSuccess != err) {
    printf("%s\n", cudaGetErrorString( err));
  }
  return cudaSuccess != err;
}

int cuda_synchronize_event(cudaEvent_t* t) {
  //cudaError_t err = cudaEventSynchronize(*t);
  cudaError_t err = cudaStreamWaitEvent(NULL, *t, 0);
  if (cudaSuccess != err) {
    printf("%s\n", cudaGetErrorString( err));
  }
  return cudaSuccess != err;
}

int cuda_create_event(cudaEvent_t* t) {
  //cudaError_t err = cudaEventCreateWithFlags(t, cudaEventBlockingSync);
  cudaError_t err = cudaEventCreate(t);
  if (cudaSuccess != err) {
    printf("%s\n", cudaGetErrorString( err));
  }
  return cudaSuccess != err;
}

int cuda_set_device(int deviceId) {
    cudaSetDevice(deviceId);
    
    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}



bool cuda_is_fermi(int deviceId) {
  cudaDeviceProp prop;
  cudaGetDeviceProperties(&prop, deviceId);
  return prop.major >= 2;
}

int cuda_set_P2P(int gpu1, int gpu2) {
  bool is_fermi = cuda_is_fermi(gpu1) && cuda_is_fermi(gpu2);
  
  int access2from1, access1from2;

  cudaDeviceCanAccessPeer(&access2from1, gpu1, gpu2);
  cudaDeviceCanAccessPeer(&access1from2, gpu2, gpu1);

  //printf("%d can access %d : %d\n ", gpu1, gpu2, access2from1);
  //printf("%d can access %d : %d\n ", gpu2, gpu1, access1from2);

  bool same_complex = false;
  if(access2from1==1 && access1from2==1) same_complex = true;

  if(is_fermi && same_complex) {
    cudaSetDevice(gpu1);
    cudaDeviceEnablePeerAccess(gpu2, 0); //second argument is flags
    cudaSetDevice(gpu2);
    cudaDeviceEnablePeerAccess(gpu1, 0); //second argument is flags
    return 0;
  } else {
    return CUDA_ERROR;
  }
}

int destroy_tex(cudamat* mat) {
  if (mat->tex_obj != 0) {
    cudaError_t err = cudaDestroyTextureObject(mat->tex_obj);
    if (cudaSuccess != err) {
      mat->tex_obj = 0;
      return 0;
    } else {
      return CUDA_ERROR;
    }
  }
  return 0;
}

int init_random(rnd_struct* rnd_state, int seed) {
    unsigned int * host_mults;
    host_mults = (unsigned int*)malloc(NUM_RND_STREAMS * sizeof(unsigned int));

    for (int i = 0; i < NUM_RND_STREAMS; i++) {
      host_mults[i] = _rand_words[i];
    }

    cublasAlloc(NUM_RND_STREAMS, sizeof(unsigned int), (void**)&rnd_state->dev_mults);
    cublasAlloc(NUM_RND_STREAMS, sizeof(unsigned long long), (void**)&rnd_state->dev_words);
    cublasSetVector(NUM_RND_STREAMS, sizeof(unsigned int), host_mults, 1, rnd_state->dev_mults, 1);
    free(host_mults);
    cudaDeviceSynchronize();

    kSeedRandom<<<NUM_RND_BLOCKS, NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, seed);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

// Allocates and gives up ownership of pointer. Caller must free.
int get_rnd_state(rnd_struct* rnd_state, unsigned long long* host_words_out, int *size_out) {
  *size_out = NUM_RND_STREAMS;
  host_words_out = (unsigned long long*)malloc(NUM_RND_STREAMS * sizeof(unsigned int));
  if (host_words_out == NULL) {
    return ERROR_GENERIC;  // Out of memory.
  }
  cublasGetVector(NUM_RND_STREAMS, sizeof(unsigned long long), rnd_state->dev_words, 1, host_words_out, 1);
  if (check_cublas_error())
    return CUBLAS_ERROR;
  else
     return 0;
}

/* ------------------------------ Utility routines ------------------------------ */

int get_leading_dimension(cudamat* mat) {
    return mat->is_trans ? mat->size[1] : mat->size[0];
}

int get_nonleading_dimension(cudamat* mat) {
    return mat->is_trans ? mat->size[0] : mat->size[1];
}

void set_transpose(cudamat* mat, int is_trans) {
    mat->is_trans = is_trans;
}

inline char get_transpose_char(cudamat* mat) {
    return mat->is_trans ? 't' : 'n';
}

void cuda_sync_threads() {
    cudaDeviceSynchronize();
}

/* ------------------------------ Allocating/moving data ------------------------------ */

int allocate_device_memory(cudamat* mat) {
    size_t len = mat->size[0]*mat->size[1];

    cublasStatus stat;

    stat = cublasAlloc(len, sizeof(mat->data_device[0]), (void**)&mat->data_device);

    if (stat != CUBLAS_STATUS_SUCCESS || check_cublas_error()) {
        checkCUDAError();
        return CUBLAS_ERROR;
    }

    mat->on_device = 1;
    return 0;
}

int allocate_device_memory_bbox(cudamat_bbox* mat) {
    int size = mat->size;
    int numboxes = mat->numboxes;

    cublasStatus stat;

    stat = cublasAlloc(size, sizeof(int), (void**)&mat->data_device.seg);
    if (stat != CUBLAS_STATUS_SUCCESS || check_cublas_error()) {
        checkCUDAError();
        return CUBLAS_ERROR;
    }
    stat = cublasAlloc(numboxes, sizeof(int), (void**)&mat->data_device.labels);
    if (stat != CUBLAS_STATUS_SUCCESS || check_cublas_error()) {
        checkCUDAError();
        return CUBLAS_ERROR;
    }
    stat = cublasAlloc(4 * numboxes, sizeof(int), (void**)&mat->data_device.boxes);
    if (stat != CUBLAS_STATUS_SUCCESS || check_cublas_error()) {
        checkCUDAError();
        return CUBLAS_ERROR;
    }

    mat->on_device = 1;
    return 0;
}

int allocate_device_memory_sparse(cudamat_sparse* mat) {
    int nnz = mat->nnz, rows = mat->size[0];

    cublasStatus stat;

    stat = cublasAlloc(nnz, sizeof(mat->data_device.data[0]), (void**)&mat->data_device.data);
    if (stat != CUBLAS_STATUS_SUCCESS || check_cublas_error()) {
        checkCUDAError();
        return CUBLAS_ERROR;
    }

    stat = cublasAlloc(nnz, sizeof(mat->data_device.indices[0]), (void**)&mat->data_device.indices);
    if (stat != CUBLAS_STATUS_SUCCESS || check_cublas_error()) {
        checkCUDAError();
        return CUBLAS_ERROR;
    }

    stat = cublasAlloc(rows + 1, sizeof(mat->data_device.indptr[0]), (void**)&mat->data_device.indptr);
    if (stat != CUBLAS_STATUS_SUCCESS || check_cublas_error()) {
        checkCUDAError();
        return CUBLAS_ERROR;
    }

    mat->on_device = 1;
    return 0;
}

int copy_to_host_slice(cudamat* mat, size_t start, size_t end) {
    if (start >= end || end > mat->size[1])
      return ERROR_GENERIC;

    size_t len = mat->size[0] * (end - start);
    size_t offset = mat->size[0] * start;

    if (mat->on_device) {
        cublasGetVector(len, sizeof(mat->data_host[0]), mat->data_device + offset, 1, mat->data_host + offset, 1);

        if (check_cublas_error())
            return CUBLAS_ERROR;
    } else
       return ERROR_NOT_ON_DEVICE;
 
    return 0;
}

int copy_to_host(cudamat* mat) {
    size_t len = mat->size[0]*mat->size[1];

    if (mat->on_device) {
        cublasGetVector(len, sizeof(mat->data_host[0]), mat->data_device, 1, mat->data_host, 1);

        if (check_cublas_error())
            return CUBLAS_ERROR;
    } else
       return ERROR_NOT_ON_DEVICE;
 
    return 0;
}

int copy_bbox_to_host(cudamat_bbox* mat) {
  if (mat->on_device) {
    cublasGetVector(mat->size, sizeof(int), mat->data_device.seg, 1, mat->data_host.seg, 1);
    cublasGetVector(mat->numboxes, sizeof(int), mat->data_device.labels, 1, mat->data_host.labels, 1);
    cublasGetVector(4 * mat->numboxes, sizeof(int), mat->data_device.boxes, 1, mat->data_host.boxes, 1);
    if (check_cublas_error()) return CUBLAS_ERROR;
  } else {
    return ERROR_NOT_ON_DEVICE;
  }
  return 0;
}

int copy_to_device_slice(cudamat* mat, size_t start, size_t end) {
    if (end <= start || end > mat->size[1])
      return ERROR_GENERIC;

    size_t len = mat->size[0] * (end - start);
    int err_code = 0;
    size_t offset = mat->size[0] * start;
    //if (!mat->owns_data)
    //    return VIEW_ERROR;

    if (!mat->on_device) {
        err_code = allocate_device_memory(mat);
        if (err_code)
            return err_code;
    }

    cublasSetVector(len, sizeof(mat->data_host[0]), mat->data_host + offset, 1, mat->data_device + offset, 1);
    
    if (check_cublas_error())
        return CUBLAS_ERROR;

    return 0;
}



int copy_to_device(cudamat* mat) {
    size_t len = mat->size[0]*mat->size[1];
    int err_code = 0;

    //if (!mat->owns_data)
    //    return VIEW_ERROR;

    if (!mat->on_device) {
        err_code = allocate_device_memory(mat);
        if (err_code)
            return err_code;
    }

    cublasSetVector(len, sizeof(mat->data_host[0]), mat->data_host, 1, mat->data_device, 1);
    cudaDeviceSynchronize();
    if (check_cublas_error())
        return CUBLAS_ERROR;



    return 0;
}

int copy_bbox_to_device(cudamat_bbox* mat) {
    int size = mat->size;
    int numboxes = mat->numboxes;
    int err_code = 0;

    //if (!mat->owns_data)
    //    return VIEW_ERROR;

    if (!mat->on_device) {
        err_code = allocate_device_memory_bbox(mat);
        if (err_code)
            return err_code;
    }

    cublasSetVector(size, sizeof(int), mat->data_host.seg, 1, mat->data_device.seg, 1);
    if (check_cublas_error())
        return CUBLAS_ERROR;
    cublasSetVector(numboxes, sizeof(int), mat->data_host.labels, 1, mat->data_device.labels, 1);
    if (check_cublas_error())
        return CUBLAS_ERROR;
    cublasSetVector(4 * numboxes, sizeof(int), mat->data_host.boxes, 1, mat->data_device.boxes, 1);
    if (check_cublas_error())
        return CUBLAS_ERROR;

    return 0;
}

int copy_sparse_to_device(cudamat_sparse* mat) {
    int len = mat->nnz, rows = mat->size[0];
    int err_code = 0;

    //if (!mat->owns_data)
    //    return VIEW_ERROR;

    if (!mat->on_device) {
        err_code = allocate_device_memory_sparse(mat);
        if (err_code)
            return err_code;
    }

    cublasSetVector(len, sizeof(mat->data_host.data[0]), mat->data_host.data, 1, mat->data_device.data, 1);
    if (check_cublas_error())
        return CUBLAS_ERROR;

    cublasSetVector(len, sizeof(mat->data_host.indices[0]), mat->data_host.indices, 1, mat->data_device.indices, 1);
    if (check_cublas_error())
        return CUBLAS_ERROR;

    cublasSetVector(rows + 1, sizeof(mat->data_host.indptr[0]), mat->data_host.indptr, 1, mat->data_device.indptr, 1);
    if (check_cublas_error())
        return CUBLAS_ERROR;

    return 0;
}

// mat 1 : source
// mat 2 : dest
int copy_on_device(cudamat* mat1, cudamat* mat2) {
    int len = mat1->size[0]*mat1->size[1];

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    cudaMemcpy(mat2->data_device, mat1->data_device, len * sizeof(float), cudaMemcpyDefault);
    //cublasScopy(len, mat1->data_device, 1, mat2->data_device, 1);

    if (check_cublas_error())
        return CUBLAS_ERROR;
    else
        return 0;
}
int copy_on_device_p2p_async(cudamat* src, cudamat* dst, int src_dev, int dst_dev) {
    int len = src->size[0]*src->size[1];

    if (src->size[0] != dst->size[0] || src->size[1] != dst->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    cudaMemcpyPeerAsync(dst->data_device, dst_dev, src->data_device, src_dev, len * sizeof(float));

    if (check_cublas_error())
        return CUBLAS_ERROR;
    else
        return 0;
}


int get_row_slice(cudamat* source, cudamat* target, unsigned int start, unsigned int end) {
    int height = source->size[0];
    int width = source->size[1];

    if ((end - start) != target->size[0] || source->size[1] != target->size[1] || start >= end || end > height)
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    dim3 kernelBlockGrid((int)ceil((end - start)/32.), (int)ceil(width/32.), 1);
    dim3 kernelBlockDim(32, 1, 1);

    kGetRowSlice<<<kernelBlockGrid,kernelBlockDim>>>(source->data_device, target->data_device, start, end, width, height);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int set_row_slice(cudamat* source, cudamat* target, unsigned int start, unsigned int end) {
    int height = target->size[0];
    int width = target->size[1];

    if ((end - start) != source->size[0] || source->size[1] != target->size[1] || start >= end || end > height)
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    dim3 kernelBlockGrid((int)ceil((end - start)/32.), (int)ceil(width/32.), 1);
    dim3 kernelBlockDim(32, 1, 1);

    kSetRowSlice<<<kernelBlockGrid,kernelBlockDim>>>(source->data_device, target->data_device, start, end, width, height);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int copy_transpose_big_matrix(cudamat* source, cudamat* target) {
    unsigned int height = source->size[0];
    unsigned int width = source->size[1];

    if (source->size[0] != target->size[1] || source->size[1] != target->size[0])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kTransposeBig<<< NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK >>>(target->data_device, source->data_device, height, width);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}


int copy_transpose(cudamat* source, cudamat* target) {
    unsigned int height = source->size[0];
    unsigned int width = source->size[1];

    if (source->size[0] != target->size[1] || source->size[1] != target->size[0])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    // setup execution parameters
    unsigned int grid_x = height / COPY_BLOCK_SIZE;
    if (height % COPY_BLOCK_SIZE)
        grid_x++;

    unsigned int grid_y = width / COPY_BLOCK_SIZE;
    if (width % COPY_BLOCK_SIZE)
        grid_y++;

    dim3 grid(grid_x, grid_y, 1);
    dim3 threads(COPY_BLOCK_SIZE, COPY_BLOCK_SIZE, 1);

    kTranspose<<< grid, threads >>>(target->data_device, source->data_device, height, width);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int free_device_memory(cudamat* mat) {
    if (mat->owns_data && mat->on_device) {
        cublasStatus stat;

        stat = cublasFree(mat->data_device);
        mat->on_device = 0;

        if (stat != CUBLAS_STATUS_SUCCESS || check_cublas_error())
            return CUBLAS_ERROR;
    }

    return 0;
}

int free_device_memory_bbox(cudamat_bbox* mat) {
    if (mat->on_device) {
        cublasStatus stat;

        stat = cublasFree(mat->data_device.seg);
        stat = cublasFree(mat->data_device.labels);
        stat = cublasFree(mat->data_device.boxes);
        mat->on_device = 0;

        if (stat != CUBLAS_STATUS_SUCCESS || check_cublas_error())
            return CUBLAS_ERROR;
    }

    return 0;
}


int set_shape(cudamat* mat, unsigned int m, unsigned int n) {

    mat->size[0] = m;
    mat->size[1] = n;

    return 0;
}

int set_shape4d(Shape4D* shape, unsigned int s1, unsigned int s2, unsigned s3, unsigned s4) {

    shape->shape[0] = s1;
    shape->shape[1] = s2;
    shape->shape[2] = s3;
    shape->shape[3] = s4;

    return 0;
}


int reshape(cudamat* mat, int m, int n) {
    if (m < 0 && n < 0)
        return ERROR_GENERIC;
    if (m < 0)
        m = (mat->size[0] * mat->size[1]) / n;
    if (n < 0)
        n = (mat->size[0] * mat->size[1]) / m;

    if (mat->size[0] * mat->size[1] != m * n)
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    mat->size[0] = m;
    mat->size[1] = n;

    return 0;
}

int get_slice(cudamat* source, cudamat* target, unsigned int first_col, unsigned int last_col) {
    if (source->is_trans)
        return ERROR_TRANSPOSED;

    if (!source->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (last_col > source->size[1] || (first_col >= last_col))
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    int num_rows = source->size[0];

    target->data_host = source->data_host + first_col * num_rows;
    target->data_device = source->data_device + first_col * num_rows;
    target->on_device = 1;
    target->on_host = 0;
    target->size[0] = source->size[0];
    target->size[1] = last_col - first_col;
    target->is_trans = 0;
    target->owns_data = 0;
    target->tex_obj = 0;

    return 0;
}

int get_vector_slice(cudamat* source, cudamat* target, unsigned int first_ind, unsigned int last_ind) {
    // source must be a vector.
    if (source->size[0] > 1 && source->size[1] > 1)
        return ERROR_GENERIC;

    if (source->is_trans)
        return ERROR_TRANSPOSED;

    if (!source->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (first_ind >= last_ind)
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    int num_rows = source->size[0];

    target->data_host = 0;
    target->data_device = source->data_device + first_ind * num_rows;
    target->on_device = 1;
    target->on_host = 0;
    target->is_trans = 0;
    target->owns_data = 0;

    if (source->size[0] > 1) {
        if (last_ind > source->size[0])
            return ERROR_INCOMPATIBLE_DIMENSIONS;

        target->size[0] = last_ind - first_ind;
        target->size[1] = 1;
    } else {
        if (last_ind > source->size[1])
            return ERROR_INCOMPATIBLE_DIMENSIONS;

        target->size[0] = 1;
        target->size[1] = last_ind - first_ind;
    }

    return 0;
}

/* ------------------------------ Initialization routines ------------------------------ */

void init_from_array(cudamat* mat, float* data, int m, int n) {
    mat->data_host = data;
    mat->size[0] = m;
    mat->size[1] = n;
    mat->on_device = 0;
    mat->on_host = 1;
    mat->is_trans = 0;
    mat->owns_data = 1;
    mat->tex_obj = 0;
}

void init_from_sparse_array(cudamat_sparse* mat, float* data, int* indices, int* indptr, int m, int n, int nnz) {
    mat->data_host.data = data;
    mat->data_host.indices = indices;
    mat->data_host.indptr = indptr;
    mat->size[0] = m;
    mat->size[1] = n;
    mat->on_device = 0;
    mat->on_host = 1;
    mat->is_trans = 0;
    mat->owns_data = 1;
    mat->nnz = nnz;
}


void set_on_device(cudamat* mat) {
  mat->on_device = 1;
}

int init_empty(cudamat* mat, int m, int n) {
    mat->size[0] = m;
    mat->size[1] = n;
    mat->on_device = 0;
    mat->on_host = 0;
    mat->is_trans = 0;
    mat->owns_data = 1;
    mat->tex_obj = 0;

    return allocate_device_memory(mat);
}

/* ------------------------------ Random number generation ------------------------------ */
int fill_with_rand(rnd_struct* rnd_state, cudamat* mat) {
    int len = mat->size[0] * mat->size[1];

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kRandomUniform<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int fill_with_randn(rnd_struct* rnd_state, cudamat* mat) {
    int len = mat->size[0] * mat->size[1];

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kRandomGaussian<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int sample_bernoulli(rnd_struct* rnd_state, cudamat* mat, cudamat* target) {
    int len = mat->size[0] * mat->size[1];
    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kSampleBernoulli<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}
int sample_bernoulli_tanh(rnd_struct* rnd_state, cudamat* mat, cudamat* target) {
    int len = mat->size[0] * mat->size[1];
    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kSampleBernoulliTanh<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}
int sample_poisson(rnd_struct* rnd_state, cudamat* mat, cudamat* target) {
    int len = mat->size[0] * mat->size[1];
    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kSamplePoisson<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}
int sample_gaussian(rnd_struct* rnd_state, cudamat* mat, cudamat* target, float mult) {
    int len = mat->size[0] * mat->size[1];
    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kSampleGaussian<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, target->data_device, len, mult);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int sample_vmf(rnd_struct* rnd_state, cudamat* kappa, cudamat* target, int num_dims, float tiny) {
    int len = kappa->size[0] * kappa->size[1];
    if (kappa->size[0] != target->size[0] || kappa->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (!kappa->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    kSampleVMF<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, kappa->data_device, target->data_device, num_dims, len, tiny);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int perturb_energy(rnd_struct* rnd_state, cudamat* mat, cudamat* target) {
    int len = mat->size[0] * mat->size[1];
    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kPerturbEnergy<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int perturb_prob(rnd_struct* rnd_state, cudamat* mat, cudamat* target) {
    int len = mat->size[0] * mat->size[1];
    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kPerturbProb<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int dropout(rnd_struct* rnd_state, cudamat* mat, float dropprob, float val, float scale) {
    int len = mat->size[0] * mat->size[1];

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kRandomDropout<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, len, dropprob, val, scale);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int gaussian_dropout(rnd_struct* rnd_state, cudamat* mat, float scale) {
    int len = mat->size[0] * mat->size[1];

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kRandomGaussianDropout<<<NUM_RND_BLOCKS,NUM_RND_THREADS_PER_BLOCK>>>(rnd_state->dev_mults, rnd_state->dev_words, mat->data_device, len, scale);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}


/* ------------------------------ Algebraic operations ------------------------------ */

int add_col_vec(cudamat* mat, cudamat* vec, cudamat* target) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[0] != vec->size[0] || vec->size[1] != 1 ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    unsigned int num_blocks = DIVUP((w * h), (NUM_VECTOR_OP_LOOPS_PER_THREAD * NUM_VECTOR_OP_THREADS_PER_BLOCK));
    num_blocks = MIN(NUM_VECTOR_OP_BLOCKS, num_blocks);
    kAddColVector<<<num_blocks,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, w, h);

    if (checkCUDAError()) {
        return CUDA_ERROR;
    }

    return 0;
}

int add_col_mult(cudamat* mat, cudamat* vec, cudamat* target, float mult) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[0] != vec->size[0] || vec->size[1] != 1 ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    unsigned int num_blocks = DIVUP((w * h), (NUM_VECTOR_OP_LOOPS_PER_THREAD * NUM_VECTOR_OP_THREADS_PER_BLOCK));
    num_blocks = MIN(NUM_VECTOR_OP_BLOCKS, num_blocks);
    kAddColMult<<<num_blocks,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, mult, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int add_to_each_pixel(cudamat* mat1, cudamat* mat2, cudamat* target, float mult) {
    unsigned int h = mat1->size[0],
                 w = mat1->size[1],
                 num_colors = mat2->size[1];

    if (!mat1->on_device || !mat2->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans || mat2->is_trans)
        return ERROR_TRANSPOSED;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] % mat2->size[1] != 0 ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kAddToEachPixel<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, mult, w, h, w / num_colors);

    if (checkCUDAError()) {
        return CUDA_ERROR;
    }

    return 0;
}


int mult_diagonal_scalar(cudamat* mat, float val, cudamat* target) {
    unsigned int w = mat->size[1];

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kMultDiagonalScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, val, target->data_device, w);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


int add_diagonal_scalar(cudamat* mat, float val, cudamat* target) {
    unsigned int w = mat->size[1];

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kAddDiagonalScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, val, target->data_device, w);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


int mult_diagonal(cudamat* mat, cudamat* vec, cudamat* target) {
    unsigned int w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[0] != vec->size[1] * vec->size[0] ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kMultDiagonal<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, w);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


int add_diagonal(cudamat* mat, cudamat* vec, cudamat* target) {
    unsigned int w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[0] != vec->size[1] * vec->size[0] ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kAddDiagonal<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, w);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


int add_row_mult(cudamat* mat, cudamat* vec, cudamat* target, float mult) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[1] != vec->size[1] || vec->size[0] != 1 ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    unsigned int num_blocks = DIVUP((w * h), (NUM_VECTOR_OP_LOOPS_PER_THREAD * NUM_VECTOR_OP_THREADS_PER_BLOCK));
    num_blocks = MIN(NUM_VECTOR_OP_BLOCKS, num_blocks);
    kAddRowMult<<<num_blocks,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, mult, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int add_row_vec(cudamat* mat, cudamat* vec, cudamat* target) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[1] != vec->size[1] || vec->size[0] != 1 ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    unsigned int num_blocks = DIVUP((w * h), (NUM_VECTOR_OP_LOOPS_PER_THREAD * NUM_VECTOR_OP_THREADS_PER_BLOCK));
    num_blocks = MIN(NUM_VECTOR_OP_BLOCKS, num_blocks);
    kAddRowVector<<<num_blocks,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int mult_by_col_vec(cudamat* mat, cudamat* vec, cudamat* target) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[0] != vec->size[0] || vec->size[1] != 1 ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kMultByColVector<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int mult_by_row_vec(cudamat* mat, cudamat* vec, cudamat* target, float scale_targets) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[1] != vec->size[1] || vec->size[0] != 1 ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (scale_targets == 0.0) {
      kMultByRowVector<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, w, h);
    } else {
      kMultByRowVectorScale<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, w, h, scale_targets);
    }

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int div_by_col_vec(cudamat* mat, cudamat* vec, cudamat* target) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[0] != vec->size[0] || vec->size[1] != 1 ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kDivByColVector<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int div_by_row_vec(cudamat* mat, cudamat* vec, cudamat* target) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !vec->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (mat->size[1] != vec->size[1] || vec->size[0] != 1 ||
        mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kDivByRowVector<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, vec->data_device, target->data_device, w, h);


    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int less_than_eq(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kLessThanEq<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int less_than(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kLessThan<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int less_than_eq_scalar(cudamat* mat, float val, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans != target->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kLessThanEqScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, val, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


int less_than_scalar(cudamat* mat, float val, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans != target->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kLessThanScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, val, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int greater_than_eq(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kGreaterThanEq<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int greater_than(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kGreaterThan<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int upper_bound(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kUpperBound<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


int lower_bound(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kLowerBound<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int greater_than_eq_scalar(cudamat* mat, float val, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans != target->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kGreaterThanEqScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, val, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int greater_than_scalar(cudamat* mat, float val, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans != target->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kGreaterThanScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, val, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int upper_bound_scalar(cudamat* mat, float val, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans != target->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kUpperBoundScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, val, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int upper_bound_mod_scalar(cudamat* mat, float val, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans != target->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kUpperBoundModScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, val, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


int lower_bound_scalar(cudamat* mat, float val, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans != target->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kLowerBoundScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, val, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int max_by_axis(cudamat* mat, cudamat* target, int axis) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (axis == 0) {
        if (target->size[0] != 1 || target->size[1] != mat->size[1])
            return ERROR_INCOMPATIBLE_DIMENSIONS;

        int shared_mem_size = 32 * sizeof(float) ;
        int w1 = floor(sqrt(w));
        int w2 = w / w1 + (w % w1 == 0 ? 0 : 1);
        dim3 gridDim(w1, w2, 1);
        kMaxColumnwise<<<gridDim, 32, shared_mem_size>>>(mat->data_device, target->data_device, w, h);

    } else
        return ERROR_UNSUPPORTED;

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int choose_max_and_accumulate(cudamat* mat, cudamat* acc) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !acc->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (acc->size[0] != mat->size[0] || acc->size[1] != mat->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

        int w1 = floor(sqrt(w));
        int w2 = w / w1 + (w % w1 == 0 ? 0 : 1);
        dim3 gridDim(w1, w2, 1);
    kChooseMaxAndAccumulate<<<gridDim,32>>>(mat->data_device, acc->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int choose_max_by_axis(cudamat* mat, cudamat* target, int axis) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (axis == 0) {
        if (target->size[0] != mat->size[0] || target->size[1] != mat->size[1])
            return ERROR_INCOMPATIBLE_DIMENSIONS;

        int shared_mem_size = 32 * sizeof(float) ;
        int w1 = floor(sqrt(w));
        int w2 = w / w1 + (w % w1 == 0 ? 0 : 1);
        dim3 gridDim(w1, w2, 1);
        kChooseMaxColumnwise<<<gridDim, 32, shared_mem_size>>>(mat->data_device, target->data_device, w, h);

    } else
        return ERROR_UNSUPPORTED;

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int argmax_by_axis(cudamat* mat, cudamat* target, int axis) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (axis == 0) {
        if (target->size[0] != 1 || target->size[1] != mat->size[1])
            return ERROR_INCOMPATIBLE_DIMENSIONS;

        int w1 = floor(sqrt(w));
        int w2 = w / w1 + (w % w1 == 0 ? 0 : 1);
        dim3 gridDim(w1, w2, 1);
        kArgMaxColumnwise<<<gridDim,32>>>(mat->data_device, target->data_device, w, h);

    } else
        return ERROR_UNSUPPORTED;

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int sqsum_by_axis(cudamat* mat, cudamat* target, int axis, float mult, float p) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (axis == 0) {
        if (target->size[0] != 1 || target->size[1] != mat->size[1])
            return ERROR_INCOMPATIBLE_DIMENSIONS;

        int shared_mem_size = 32 * sizeof(float) ;
        int w1 = floor(sqrt(w));
        int w2 = (w + w1 - 1) / w1;
        dim3 gridDim(w1, w2, 1);
        kSqSumColumnwise<<<gridDim, 32, shared_mem_size>>>(mat->data_device, target->data_device, w, h, mult, p);
    } else if (axis == 1) {
        if (target->size[1] != 1 || target->size[0] != mat->size[0])
            return ERROR_INCOMPATIBLE_DIMENSIONS;

        int shared_mem_size = 32 * sizeof(float) ;
        int h1 = floor(sqrt(h));
        int h2 = (h + h1 - 1) / h1;
        dim3 gridDim(h1, h2, 1);
        kSqSumRowwise<<<gridDim, 32, shared_mem_size>>>(mat->data_device, target->data_device, w, h, mult, p);
    } else
        return ERROR_UNSUPPORTED;

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

// Avoids using ones vector.
float sum_all(cudamat* mat, cudamat* temp, int* err_code) {
    unsigned long long len = mat->size[0] * mat->size[1];
    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;
    const int max_num_blocks = MIN(8, temp->size[0] * temp->size[1]);  // Should be around max number of concurrent blocks.
    float res_host[8];
    float* res_device = temp->data_device;
    int num_blocks = MIN(max_num_blocks, DIVUP(len, 4 * NUM_VECTOR_OP_THREADS_PER_BLOCK));
    int shared_mem_size = NUM_VECTOR_OP_THREADS_PER_BLOCK * sizeof(float) ;
    int left_over = len % num_blocks;
    unsigned long long len_per_block = len / num_blocks;
    kSumAll<<<num_blocks, NUM_VECTOR_OP_THREADS_PER_BLOCK, shared_mem_size>>>(
        mat->data_device, res_device, len, len_per_block, left_over);
    cudaDeviceSynchronize();
    cudaMemcpy(res_host, res_device, num_blocks * sizeof(float), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    float val = 0.0f;
    for (int i = 0; i < num_blocks; ++i) val += res_host[i];
    if (checkCUDAError()) {
        *err_code = CUDA_ERROR;
    }
    return val;
}


int sum_by_axis(cudamat* mat, cudamat* target, int axis, float mult, float p) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (axis == 0) {
        if (target->size[0] != 1 || target->size[1] != mat->size[1])
            return ERROR_INCOMPATIBLE_DIMENSIONS;

        int shared_mem_size = 32 * sizeof(float) ;
        int w1 = floor(sqrt(w));
        int w2 = (w + w1 - 1) / w1;
        dim3 gridDim(w1, w2, 1);
        kSumColumnwise<<<gridDim, 32, shared_mem_size>>>(mat->data_device, target->data_device, w, h, mult, p);
    } else if (axis == 1) {
        if (target->size[1] != 1 || target->size[0] != mat->size[0])
            return ERROR_INCOMPATIBLE_DIMENSIONS;

        int num_blocks = DIVUP(h, NUM_VECTOR_OP_THREADS_PER_BLOCK);
        int h1 = floor(sqrt(num_blocks));
        int h2 = DIVUP(num_blocks, h1);
        dim3 gridDim(h1, h2, 1);
        kSumRowwise<<<gridDim, NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, w, h, mult, p);
    } else
        return ERROR_UNSUPPORTED;

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int bn_bprop_inplace(cudamat* deriv, cudamat* act, cudamat* dgamma) {
    unsigned int h = deriv->size[0],
                 w = deriv->size[1];

    if (!deriv->on_device || !act->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (deriv->is_trans || act->is_trans)
        return ERROR_TRANSPOSED;

    if (act->size[0] != h || act->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (dgamma->size[0] != 1 || dgamma->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    int shared_mem_size = 32 * sizeof(float) ;
    kBNBpropInplace<<<w, 32, shared_mem_size>>>(deriv->data_device, act->data_device, dgamma->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


int normalize_by_axis(cudamat* mat, cudamat* target, int axis) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != mat->size[0] || target->size[1] != mat->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    int shared_mem_size = 32 * sizeof(float) ;
    if (axis == 0) {
        int w1 = floor(sqrt(w));
        int w2 = DIVUP(w, w1);
        dim3 gridDim(w1, w2, 1);
        kNormalizeColumnwise<<<gridDim,32, shared_mem_size>>>(mat->data_device, target->data_device, w, h);
    } else {
      return ERROR_UNSUPPORTED;
    }
    if (checkCUDAError())
        return CUDA_ERROR;
    return 0;
}

int normlimit_by_axis(cudamat* mat, cudamat* target, int axis,
                                   float norm, int constraint) {
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != mat->size[0] || target->size[1] != mat->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    int shared_mem_size = 32 * sizeof(float) ;
    if (axis == 0) {
        int w1 = floor(sqrt(w));
        int w2 = DIVUP(w, w1);
        dim3 gridDim(w1, w2, 1);
        kNormLimitColumnwise<<<gridDim,32, shared_mem_size>>>(mat->data_device, target->data_device, norm, w, h, constraint);
    } else {
        int h1 = floor(sqrt(h));
        int h2 = DIVUP(h, h1);
        dim3 gridDim(h1, h2, 1);
        kNormLimitRowwise<<<gridDim,32, shared_mem_size>>>(mat->data_device, target->data_device, norm, w, h, constraint);
    }
    if (checkCUDAError())
        return CUDA_ERROR;
    return 0;
}

int norm_bprop_rowwise(cudamat* deriv, cudamat* input, cudamat* target) {
    unsigned int h = input->size[0],
                 w = input->size[1];

    if (!input->on_device || !target->on_device || !deriv->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (input->is_trans || deriv->is_trans || target->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != input->size[0] || target->size[1] != input->size[1] ||
        deriv->size[0] != input->size[0] || deriv->size[1] != input->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    int shared_mem_size = 32 * sizeof(float) ;
    int h1 = floor(sqrt(h));
    int h2 = DIVUP(h, h1);
    dim3 gridDim(h1, h2, 1);
    kNormalizeRowwiseBprop<<<gridDim,32, shared_mem_size>>>(deriv->data_device, input->data_device, target->data_device, w, h);
    if (checkCUDAError())
        return CUDA_ERROR;
    return 0;
}

int sign(cudamat* mat, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans != target->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kSign<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int apply_cos(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kApplyCos<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int apply_sin(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kApplySin<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_sigmoid(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kApplySigmoid<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_tanh(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kApplyTanh<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_abs(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kApplyAbs<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_log_1_plus_exp(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kApplyLog1PlusExp<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

// target = 2 / (1 + exp(-mat * lambda)) - 1
int apply_relu_squash(cudamat* mat, cudamat* target, float lambda) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kSquashRelu<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len, lambda);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_log(cudamat* mat, cudamat* target, float tiny) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kLog<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len, tiny);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_exp(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kExp<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int apply_ceil(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kCeil<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int apply_floor(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kFloor<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}



int apply_sqrt(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kSqrt<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_pow(cudamat* mat, float pow, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kPow<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, pow, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_pow_matrix(cudamat* mat, cudamat* pow, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (mat->size[0] != pow->size[0] || mat->size[1] != pow->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kPowMatrix<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, pow->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int compute_cross_entropy(cudamat* dist1, cudamat* dist2, cudamat* target, float tiny) {
    unsigned int len = dist1->size[0] * dist1->size[1];

    if (!dist1->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (dist1->size[0] != target->size[0] || dist1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (dist1->size[0] != dist2->size[0] || dist1->size[1] != dist2->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kCrossEntropy<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(dist1->data_device, dist2->data_device, target->data_device, len, tiny);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int compute_cross_entropy_bernoulli(cudamat* mat, cudamat* pow, cudamat* target, float tiny) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (mat->size[0] != pow->size[0] || mat->size[1] != pow->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kCrossEntropyBernoulli<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, pow->data_device, target->data_device, len, tiny);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int correct_preds(cudamat* mat, cudamat* pow, cudamat* target, float cutoff) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (mat->size[0] != pow->size[0] || mat->size[1] != pow->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kCorrectPreds<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, pow->data_device, target->data_device, len, cutoff);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int reciprocal(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kReciprocal<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int bessel_ratio_activation(cudamat* mat, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kBesselRatioActivation<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int bessel_ratio_activation_continued_fraction(cudamat* mat, cudamat* target, float order, int num_steps) {
    unsigned int len = mat->size[0] * mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kBesselRatioActivationContinuedFraction<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, target->data_device, order, num_steps, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


// target = beta * target + alpha * mat1 * mat2
int dot(cudamat* mat1, cudamat* mat2, cudamat* target, float beta, float alpha) {
    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    int m = get_leading_dimension(mat1),
        k2 = get_nonleading_dimension(mat1),
        k = get_leading_dimension(mat2),
        n = get_nonleading_dimension(mat2),
        m2 = get_leading_dimension(target),
        n2 = get_nonleading_dimension(target);
    if (m != m2 || n != n2 || k != k2) {
        printf("%d %d %d %d %d %d\n", m, k2, k, n, m2, n2);
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    }

    cublasSgemm(get_transpose_char(mat1), get_transpose_char(mat2), 
                m, n, k,
                alpha, mat1->data_device, mat1->size[0],
                mat2->data_device, mat2->size[0],
                beta, target->data_device, target->size[0]);

    if (check_cublas_error())
        return CUBLAS_ERROR;

    return 0;
}

int sparse_dot(cudamat_sparse* mat1, cudamat* mat2, cudamat* target, float beta, float alpha) {
    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;
    int m = mat1->size[0],
        k = mat1->size[1],
        k2 = mat2->size[0],
        n = mat2->size[1];

    if (k != k2) {
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    }
    unsigned int grid_x = m / COPY_BLOCK_SIZE;
    if (m % COPY_BLOCK_SIZE)
        grid_x++;

    unsigned int grid_y = n / COPY_BLOCK_SIZE;
    if (n % COPY_BLOCK_SIZE)
        grid_y++;

    dim3 grid(grid_x, grid_y, 1);
    dim3 threads(COPY_BLOCK_SIZE, COPY_BLOCK_SIZE, 1);

    kSparseDot<<<grid, threads>>>(m, n, k, mat1->data_device.data,
        mat1->data_device.indptr,
        mat1->data_device.indices,
        mat2->data_device, target->data_device, beta, alpha);
    if (check_cublas_error())
        return CUBLAS_ERROR;

    return 0;
}


float vdot(cudamat* mat1, cudamat* mat2, int* err_code) {
    unsigned long long len = mat1->size[0] * mat1->size[1];
    float res;
    *err_code = 0;
    if (!mat1->on_device || !mat2->on_device) {
        *err_code = ERROR_NOT_ON_DEVICE;
        return 0;
    }

    if (mat1->is_trans != mat2->is_trans) {
        *err_code = ERROR_TRANSPOSEDNESS;
        return 0;
    }

    if (mat2->size[0] * mat2->size[1] != len) {
        *err_code = ERROR_INCOMPATIBLE_DIMENSIONS;
        return 0;
    }

    if (check_cublas_error()) {
        *err_code = BEFORE_CALL_CUBLAS_ERROR;
        return 0;
    }
    if (checkCUDAError()) {
        *err_code = BEFORE_CALL_CUDA_ERROR;
        return 0;
    }
    res = cublasSdot(len, mat1->data_device, 1, mat2->data_device, 1);

    if (check_cublas_error()) {
        *err_code = CUBLAS_ERROR;
        return 0;
    }
    return res;
}

/* Perform the operation mat1 = mat1 + alpha * mat2. mat1 and mat2 must
   have the same transposedness. */
int add_mult(cudamat* mat1, cudamat* mat2, float alpha) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    cublasSaxpy(len, alpha, mat2->data_device, 1, mat1->data_device, 1);

    if (check_cublas_error())
        return CUBLAS_ERROR;

    return 0;
}
int add_mult_sign(cudamat* mat1, cudamat* mat2, float mult) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kAddMultSign<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, len, mult);

    if (check_cublas_error())
        return CUBLAS_ERROR;

    return 0;
}


int add_elementwise(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kAdd<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int subtract_elementwise(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kSubtract<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int divide_elementwise(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kDivide<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

/* Elementwise multiplication of 2 matrices */
int mult_elementwise(cudamat* mat1, cudamat* mat2, cudamat* target, float scale_targets) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kMult<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len, scale_targets);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_sin_deriv(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kSinDeriv<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int apply_cos_deriv(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kCosDeriv<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int apply_logistic_deriv(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kLogisticDeriv<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

// mat1 - output of network
// mat2 - target
// out_grad - output gradient
int apply_logistic_grad(cudamat* mat1, cudamat* mat2, cudamat* out_grad) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !out_grad->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != out_grad->size[0] || mat1->size[1] != out_grad->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kLogisticGrad<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, out_grad->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

// mat1 - output of network
// mat2 - target
// out - .
int get_logistic_correct_normalized(cudamat* mat1, cudamat* mat2, cudamat* out) {

    if (!mat1->on_device || !mat2->on_device || !out->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != out->size[0] || 1 != out->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    int num_blocks = DIVUP(mat1->size[0], NUM_VECTOR_OP_THREADS_PER_BLOCK);
    kLogisticCorrectNormalized<<<num_blocks, NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, out->data_device, mat1->size[0], mat1->size[1]);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_tanh_deriv(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kTanhDeriv<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_rectified_linear_deriv(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kRectifiedLinearDeriv<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_rectified_linear_smooth_deriv(cudamat* mat1, cudamat* mat2, cudamat* target) {
    int len = mat1->size[0]*mat1->size[1];

    if (!mat1->on_device || !mat2->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat1->is_trans != mat2->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (mat1->size[0] != mat2->size[0] || mat1->size[1] != mat2->size[1] ||
        mat1->size[0] != target->size[0] || mat1->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kRectifiedLinearSmoothDeriv<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat1->data_device, mat2->data_device, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}
int assign_scalar(cudamat* mat, float alpha) {
    unsigned long long len = mat->size[0] * mat->size[1];

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    kAssignScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(
        mat->data_device, alpha, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int write_at(cudamat* mat, int row, int col, float val) {
    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;
    if (row >= mat->size[0] || col >= mat->size[1] || row < 0 || col < 0)
      return ERROR_INCOMPATIBLE_DIMENSIONS;

    cudaMemcpy(mat->data_device + col * mat->size[0] + row, &val, sizeof(float), cudaMemcpyHostToDevice);
    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

float read_from(cudamat* mat, int row, int col, int* err_code) {
    *err_code = 0;
    if (!mat->on_device)
        *err_code = ERROR_NOT_ON_DEVICE;
    if (row >= mat->size[0] || col >= mat->size[1] || row < 0 || col < 0)
        *err_code = ERROR_INCOMPATIBLE_DIMENSIONS;

    float val = 0;
    cudaMemcpy(&val, mat->data_device + col * mat->size[0] + row, sizeof(float), cudaMemcpyDeviceToHost);
    if (checkCUDAError())
        *err_code = CUDA_ERROR;

    return val;
}

int mult_by_scalar(cudamat* mat, float alpha, cudamat* target, float scale_targets) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kMultScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, alpha, target->data_device, len, scale_targets);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int divide_by_scalar(cudamat* mat, float alpha, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kDivideScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, alpha, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int add_scalar(cudamat* mat, float alpha, cudamat* target) {
    int len = mat->size[0]*mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kAddScalar<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, alpha, target->data_device, len);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

float euclid_norm(cudamat* mat, int* err_code) {
    int len = mat->size[0]*mat->size[1];

    float res =  cublasSnrm2(len, mat->data_device, 1);

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (check_cublas_error()) {
        *err_code = CUBLAS_ERROR;
        return -1.;
    } else {
        *err_code = 0;
        return res;
    }
}
int selectRows(cudamat* source, cudamat* target, cudamat* indices){
    const int nRetRows = indices->size[1];

    if (nRetRows==0) return 0;

    dim3 gridDim((nRetRows+31)/32);
    dim3 blockDim(32);

    kSelectRows<<<gridDim, blockDim>>>(source->data_device, target->data_device, indices->data_device, nRetRows, source->size[0], source->size[1]);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}


int swapColumns(cudamat* source, cudamat* target, cudamat* indices1, cudamat* indices2){
    const int cols = indices1->size[1]*indices1->size[0],
                 h = source->size[0],
                 w = source->size[1];

    kSwapColumns<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(source->data_device, target->data_device, indices1->data_device, indices2->data_device, cols, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int shuffleColumns(cudamat* source, cudamat* rand_perm_indices) {
    const int h = source->size[0],
              w = source->size[1];
    if (rand_perm_indices->size[0] != 1 || rand_perm_indices->size[1] != w) {
      return ERROR_INCOMPATIBLE_DIMENSIONS;
    }

    kShuffleColumns<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(source->data_device, source->data_device, rand_perm_indices->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int setSelectedRows(cudamat* target, cudamat* source, cudamat* indices){
    const int nSetRows = indices->size[1];

    if (nSetRows==0)
        return 0;

    dim3 gridDim((nSetRows+31)/32);
    dim3 blockDim(32);

    kSetSelectedRows<<<gridDim, blockDim>>>(target->data_device, source->data_device, indices->data_device, nSetRows, target->size[0], target->size[1]);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int generate_translations_big_var_off(cudamat* source, cudamat* target, cudamat* off_x, cudamat* off_y, int source_w, int target_w, int num_channels) {
    dim3 kernelBlockGrid(source->size[1], 1, 1);
    dim3 kernelBlockDim(512, 1, 1);

    kGenerateTranslationsBigVarOff<<<kernelBlockGrid, kernelBlockDim>>>(source->data_device, target->data_device, off_x->data_device, off_y->data_device, source_w, target_w, num_channels);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int extract_patches(cudamat* images, cudamat* patches, cudamat* width_offset, cudamat* height_offset, cudamat* flip, int img_width, int img_height, int patch_width, int patch_height) {
  int num_images = images->size[1];
  int num_colors = images->size[0] / (img_width * img_height);

  if (patches->size[1]  != num_colors * patch_width * patch_height || patches->size[0] != num_images)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  if (width_offset->size[0] * width_offset->size[1] != num_images)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  if (height_offset->size[0] * height_offset->size[1] != num_images)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  if (flip->size[0] * flip->size[1] != num_images)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

    unsigned int grid_y = patch_height / COPY_BLOCK_SIZE;
    if (patch_height % COPY_BLOCK_SIZE)
        grid_y++;

    unsigned int grid_x = patch_width / COPY_BLOCK_SIZE;
    if (patch_width % COPY_BLOCK_SIZE)
        grid_x++;

    dim3 grid(grid_x, grid_y, num_images * num_colors);
    dim3 threads(COPY_BLOCK_SIZE, COPY_BLOCK_SIZE);


  kExtractPatches2<<<grid, threads>>>(
      images->data_device, patches->data_device, width_offset->data_device,
      height_offset->data_device, flip->data_device, num_images, img_width, img_height,
      patch_width, patch_height, num_colors);
  //*/
  /*
  kExtractPatches<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(
      images->data_device, patches->data_device, indices->data_device, width_offset->data_device,
      height_offset->data_device, num_images, img_width, img_height,
      patch_width, patch_height, num_colors);
   */

  if (checkCUDAError())
    return CUDA_ERROR;
  return 0;
}

int extract_patches_3(cudamat* images, cudamat* patches, cudamat* width_offset,
    cudamat* height_offset, cudamat* flip, int img_width, int img_height,
    int patch_width, int patch_height) {

  int num_images = images->size[1];
  int num_colors = images->size[0] / (img_width * img_height);

  if (patches->size[0] != num_colors * patch_width * patch_height || patches->size[1] != num_images)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  if (width_offset->size[0] * width_offset->size[1] != num_images)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  if (height_offset->size[0] * height_offset->size[1] != num_images)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  if (flip->size[0] * flip->size[1] != num_images)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

    unsigned int threads_y = (patch_height < COPY_BLOCK_SIZE) ? patch_height : COPY_BLOCK_SIZE;
    unsigned int threads_x = (patch_width  < COPY_BLOCK_SIZE) ? patch_width  : COPY_BLOCK_SIZE;
    unsigned int grid_y = (patch_height + threads_y - 1) / threads_y;
    unsigned int grid_x = (patch_width  + threads_x - 1) / threads_x;
    unsigned int grid_z = num_images * num_colors;
    if (grid_z > 65535) grid_z = 65535;
    dim3 grid(grid_x, grid_y, grid_z);
    dim3 threads(threads_x, threads_y);

  kExtractPatches3<<<grid, threads>>>(
      images->data_device, patches->data_device, width_offset->data_device,
      height_offset->data_device, flip->data_device, num_images, img_width, img_height,
      patch_width, patch_height, num_colors);

  if (checkCUDAError())
    return CUDA_ERROR;
  return 0;
}

int capsulify(cudamat* images, cudamat* output, int image_size, int crop_size) {
  int num_images = images->size[1];
  if (output->size[0] != images->size[0] || output->size[1] != images->size[1])
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (images->size[0] != image_size * image_size)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (image_size % crop_size != 0)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  unsigned int threads_y = (image_size < COPY_BLOCK_SIZE) ? image_size : COPY_BLOCK_SIZE;
  unsigned int threads_x = (image_size < COPY_BLOCK_SIZE) ? image_size : COPY_BLOCK_SIZE;
  unsigned int grid_y = (image_size + threads_y - 1) / threads_y;
  unsigned int grid_x = (image_size + threads_x - 1) / threads_x;
  unsigned int grid_z = num_images;
  dim3 grid(grid_x, grid_y, grid_z);
  dim3 threads(threads_x, threads_y);

  kCapsulify<<<grid, threads>>>(images->data_device, output->data_device,
                                image_size, crop_size, num_images);

  if (checkCUDAError())
    return CUDA_ERROR;
  return 0;
}


int rectify_bounding_boxes(cudamat* boxes, cudamat* width_offset, cudamat* height_offset, cudamat* flip, int patch_width, int patch_height) {
    int num_images = boxes->size[0];

    if (width_offset->size[0] * width_offset->size[1] != num_images)
      return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (height_offset->size[0] * height_offset->size[1] != num_images)
      return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (flip->size[0] * flip->size[1] != num_images)
      return ERROR_INCOMPATIBLE_DIMENSIONS;

    int num_locs = boxes->size[1] / 4;
    dim3 grid(MIN(NUM_VECTOR_OP_BLOCKS, num_locs));
    dim3 threads(MIN(NUM_VECTOR_OP_THREADS_PER_BLOCK, num_images));


    kRectifyBoundingBox<<<grid, threads>>>(
        boxes->data_device, width_offset->data_device, height_offset->data_device,
        flip->data_device, num_images, patch_width, patch_height, num_locs);

    if (checkCUDAError())
        return CUDA_ERROR;
    return 0;
}


int blockify(cudamat* source, cudamat* target, int blocksize) {
    dim3 kernelBlockGrid(source->size[1], 1, 1);
    dim3 kernelBlockDim(512, 1, 1);
    kBlockify<<<kernelBlockGrid, kernelBlockDim>>>(source->data_device, target->data_device, source->size[0], blocksize);
    if (checkCUDAError())
        return CUDA_ERROR;
    return 0;
}


int softmax(cudamat* mat, cudamat* target) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    int shared_mem_size = 32 * sizeof(float) ;

    int w1 = floor(sqrt(w));
    int w2 = w / w1 + (w % w1 == 0 ? 0 : 1);
    dim3 gridDim(w1, w2, 1);
    kSoftMax<<<gridDim, 32, shared_mem_size>>>(mat->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int softmax_overwrite(cudamat* mat) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    int shared_mem_size = 32 * sizeof(float) ; 
    int w1 = floor(sqrt(w));
    int w2 = w / w1 + (w % w1 == 0 ? 0 : 1);
    dim3 gridDim(w1, w2, 1);
    kSoftMaxOverwrite<<<gridDim, 32, shared_mem_size>>>(mat->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int softmax_row_major(cudamat* mat, cudamat* target) {
    return softmax_row_major_multi(mat, mat->size[1], target);
}

int softmax_row_major_multi(cudamat* mat, int numslices, cudamat* target) {
    unsigned int len = mat->size[0] * mat->size[1];
    unsigned int h = len / numslices;

    if (mat->size[0] != target->size[0] || mat->size[1] != target->size[1])
      return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (len % numslices != 0)
      return ERROR_INCOMPATIBLE_DIMENSIONS;

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans || target->is_trans)
        return ERROR_TRANSPOSED;

    int shared_mem_size = 32 * sizeof(float) ; 
    int h1 = floor(sqrt(h));
    int h2 = h / h1 + (h % h1 == 0 ? 0 : 1);
    dim3 gridDim(h1, h2, 1);
    kSoftMaxRowMajor<<<gridDim, 32, shared_mem_size>>>(mat->data_device, numslices, h, target->data_device);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_softmax_grad(cudamat* mat, cudamat* labels, cudamat* target) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (labels->size[0] != 1 || labels->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    kSoftMaxGrad<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, labels->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_softmax_grad_CLS(cudamat* mat, cudamat_bbox* labels, cudamat* indices, cudamat* target) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    kSoftMaxGradCLS<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(
        mat->data_device, labels->data_device.labels, indices->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;

}
int apply_softmax_grad_row_major(cudamat* mat, cudamat* labels, cudamat* target) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (labels->size[0] * labels->size[1] != h)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    kSoftMaxGradRowMajor<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, labels->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int hinge_loss_row_major(cudamat* mat, cudamat* labels, cudamat* target, int quadratic, float margin) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (labels->size[0] * labels->size[1] != h)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    int num_blocks = (h + 31) / 32;
    if (quadratic == 1) {
      kHingeQuadraticRowMajor<<<num_blocks, 32>>>(mat->data_device, labels->data_device, target->data_device, w, h, margin);
    } else {
      kHingeLinearRowMajor<<<num_blocks, 32>>>(mat->data_device, labels->data_device, target->data_device, w, h, margin);
    }

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int apply_grad_bbox(
    cudamat* mat, cudamat_bbox* bbox, cudamat* indices, cudamat* width_offset,
    cudamat* height_offset, cudamat* target, int width, int height, int depth,
    float scale_width, float scale_height, int loss_function) {

    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device || !bbox->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
   
    if (loss_function == 0) {
      //int grid_y = DIVUP(height, COPY_BLOCK_SIZE);
      //int grid_x = DIVUP(width, COPY_BLOCK_SIZE) * h;
      dim3 grid(width, height, depth);
      dim3 threads(h, 1, 1);
      kBoundingBoxLogisticGrad<<<grid, threads>>>(
          mat->data_device, bbox->data_device.boxes, bbox->data_device.labels,
          bbox->data_device.seg, indices->data_device, width_offset->data_device,
          height_offset->data_device, h, width, height, depth, scale_width,
          scale_height, target->data_device);
   
    } else {
      kBoundingBoxSoftMaxGrad<<<NUM_VECTOR_OP_BLOCKS, NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(
          mat->data_device, bbox->data_device.boxes, bbox->data_device.labels,
          bbox->data_device.seg, indices->data_device, width_offset->data_device,
          height_offset->data_device, h, width, height, depth, scale_width,
          scale_height, target->data_device);
    }
    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}



int get_softmax_correct(cudamat* mat, cudamat* labels, cudamat* target) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != 1 || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (labels->size[0] != 1 || labels->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    int w1 = floor(sqrt(w));
    int w2 = w / w1 + (w % w1 == 0 ? 0 : 1);
    dim3 gridDim(w1, w2, 1);
    kSoftMaxCorrect<<<gridDim, 32>>>(mat->data_device, labels->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int get_softmax_correct_row_major(cudamat* mat, cudamat* labels, cudamat* target) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != 1)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (labels->size[0] * labels->size[1] != h)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    int h1 = floor(sqrt(h));
    int h2 = h / h1 + (h % h1 == 0 ? 0 : 1);
    dim3 gridDim(h1, h2, 1);
    kSoftMaxCorrectRowMajor<<<gridDim, 32>>>(mat->data_device, labels->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int get_softmax_correct_CLS(cudamat* mat, cudamat_bbox* labels, cudamat* indices, cudamat* target) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device || !indices->on_device || !labels->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] * target->size[1] != h)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (indices->size[0]  * indices->size[1] != h)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    int h1 = floor(sqrt(h));
    int h2 = h / h1 + (h % h1 == 0 ? 0 : 1);
    dim3 gridDim(h1, h2, 1);
    kSoftMaxCorrectCLS<<<gridDim, 32>>>(mat->data_device, labels->data_device.labels, indices->data_device, target->data_device, w, h);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}



int get_softmax_correct_row_major_bbox(cudamat* mat, cudamat_bbox* bbox, cudamat* indices, cudamat* width_offset, cudamat* height_offset, cudamat* target, int width, int height, int depth, float scale_width, float scale_height) { 
    unsigned int h = mat->size[0] * width * height;

    if (!mat->on_device || !target->on_device || !bbox->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] * target->size[1] != h) {
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    }
    
    int h1 = floor(sqrt(h));
    int h2 = h / h1 + (h % h1 == 0 ? 0 : 1);
    dim3 gridDim(h1, h2, 1);

    kSoftMaxCorrectBoundingBox<<<gridDim, 32>>>(
        mat->data_device, bbox->data_device.boxes, bbox->data_device.labels,
        bbox->data_device.seg, indices->data_device, width_offset->data_device,
        height_offset->data_device, mat->size[0], width,
        height, depth, scale_width, scale_height, target->data_device);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int get_logistic_correct_row_major_bbox(cudamat* mat, cudamat_bbox* bbox, cudamat* indices, cudamat* width_offset, cudamat* height_offset, cudamat* target, int width, int height, int depth, float scale_width, float scale_height, float cutoff) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device || !bbox->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
   
    int grid_y = DIVUP(height, COPY_BLOCK_SIZE);
    int grid_x = DIVUP(width, COPY_BLOCK_SIZE) * h;
    dim3 grid(grid_x, grid_y, depth);
    dim3 threads(COPY_BLOCK_SIZE, COPY_BLOCK_SIZE, 1);
    kLogisticCorrectBoundingBox<<<grid, threads>>>(
        mat->data_device, bbox->data_device.boxes, bbox->data_device.labels,
        bbox->data_device.seg, indices->data_device, width_offset->data_device,
        height_offset->data_device, h, width, height, depth, scale_width,
        scale_height, target->data_device, cutoff);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}



int accumulate_columns(cudamat* mat, cudamat* indices, cudamat* target, float mult, int avg) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1],
                 w2 = target->size[1];

    if (!mat->on_device || !indices->on_device|| !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (indices->size[0] != 1 || indices->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (NUM_VECTOR_OP_THREADS_PER_BLOCK < w2)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    kAccumulateColumns<<<h, NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, indices->data_device, target->data_device, w, w2, h, mult, avg);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int get_softmax_cross_entropy(cudamat* mat, cudamat* labels, cudamat* target, float tiny) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != 1 || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (labels->size[0] != 1 || labels->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    kSoftMaxCrossEntropy<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, labels->data_device, target->data_device, w, h, tiny);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}

int get_softmax_cross_entropy_row_major(cudamat* mat, cudamat* labels, cudamat* target, float tiny) { 
    unsigned int h = mat->size[0],
                 w = mat->size[1];

    if (!mat->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != 1)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (labels->size[0] != h || labels->size[1] != 1)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    
    kSoftMaxCrossEntropyRowMajor<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(mat->data_device, labels->data_device, target->data_device, w, h, tiny);

    if (checkCUDAError())
        return CUDA_ERROR;

    return 0;
}


int expand(cudamat* source, cudamat* indices, cudamat* target){
    unsigned int h = source->size[0],
                 w = source->size[1],
                 w2 = target->size[1];

    if (!source->on_device || !indices->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (source->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (indices->size[0] != 1 || indices->size[1] != w2)
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kExpand<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(source->data_device, indices->data_device, target->data_device, h, w, w2);
    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}


int expand_and_add(cudamat* source, cudamat* mat, cudamat* indices, cudamat* target, float mult){
    unsigned int h = source->size[0],
                 w = source->size[1],
                 w2 = mat->size[1];

    if (!source->on_device || !mat->on_device || !indices->on_device || !target->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (mat->is_trans)
        return ERROR_TRANSPOSED;

    if (target->size[0] != h || target->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (indices->size[0] != 1 || indices->size[1] != w)
        return ERROR_INCOMPATIBLE_DIMENSIONS;
    if (mat->size[0] != h)
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kExpandAndAdd<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(source->data_device, mat->data_device, indices->data_device, target->data_device, w, h, mult, w2);

    if (checkCUDAError())
        return CUDA_ERROR;
    else
        return 0;
}

int adagrad(cudamat* history, cudamat* grad, float delta) {
    int len = history->size[0] * history->size[1];
    int trans = history->is_trans;

    if (!history->on_device || !grad->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (trans != grad->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (len != grad->size[0] * grad->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kAdagrad<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(
        history->data_device, grad->data_device, delta, len);

    if (check_cublas_error())
        return CUBLAS_ERROR;

    return 0;
}

int rms_prop(cudamat* history, cudamat* grad, float factor) {
    int len = history->size[0] * history->size[1];
    int trans = history->is_trans;

    if (!history->on_device || !grad->on_device)
        return ERROR_NOT_ON_DEVICE;

    if (trans != grad->is_trans)
        return ERROR_TRANSPOSEDNESS;

    if (len != grad->size[0] * grad->size[1])
        return ERROR_INCOMPATIBLE_DIMENSIONS;

    kRMSProp<<<NUM_VECTOR_OP_BLOCKS,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(
        history->data_device, grad->data_device, factor, len);

    if (check_cublas_error())
        return CUBLAS_ERROR;

    return 0;
}

int lstm_fprop(cudamat* s_in, cudamat* s_out, cudamat* w_dense, cudamat* w_diag, cudamat* b, bool init, bool use_relu) {
  int numcases = s_in->size[0];
  int num_lstms = s_in->size[1] / 6;

  if (!init) {
    // Fprop from previous hidden state to all gates.
    // This is the only dense operation, everything else is mostly elementwise (done in kLSTMFprop).
    cublasSgemm('n', 't', numcases, 4 * num_lstms, num_lstms,
                1,
                s_in->data_device,
                numcases,
                w_dense->data_device, 4 * num_lstms,
                1,
                s_out->data_device + numcases * num_lstms * 2,
                numcases);
    if (checkCUDAError()) {
        printf("Error in dot prod.\n");
      return CUDA_ERROR;
    }
  }

  int num_blocks = DIVUP(numcases * num_lstms, NUM_VECTOR_OP_THREADS_PER_BLOCK);
  num_blocks = MIN(NUM_VECTOR_OP_BLOCKS, num_blocks);
  kLSTMFprop<<<num_blocks,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(
      s_in->data_device, s_out->data_device, w_diag->data_device, b->data_device, numcases, num_lstms, init, use_relu);

  if (checkCUDAError()) {
      printf("Error in lstm.\n");
    return CUDA_ERROR;
  }
  return 0;
}

int lstm_bprop(cudamat* s_in, cudamat* s_out, cudamat* d_in, cudamat* d_out, cudamat* w_dense, cudamat* w_diag, bool init, bool use_relu) {
  int numcases = s_in->size[0];
  int num_lstms = s_in->size[1] / 6;

  int num_blocks = DIVUP(numcases * num_lstms, NUM_VECTOR_OP_THREADS_PER_BLOCK);
  num_blocks = MIN(NUM_VECTOR_OP_BLOCKS, num_blocks);
  kLSTMBprop<<<num_blocks,NUM_VECTOR_OP_THREADS_PER_BLOCK>>>(
      s_in->data_device, s_out->data_device, d_in->data_device, d_out->data_device, w_diag->data_device, numcases, num_lstms, init, use_relu);
  if (checkCUDAError())
    return CUDA_ERROR;
 
  if (!init) { 
    cublasSgemm('n', 'n', numcases, num_lstms, 4 * num_lstms,
                1,
                d_out->data_device + numcases * num_lstms * 2,
                numcases,
                w_dense->data_device, 4 * num_lstms,
                1,
                d_in->data_device,
                numcases);
    if (check_cublas_error())
      return CUBLAS_ERROR;
  }

  return 0;
}

int lstm_outp(cudamat* s_in, cudamat* s_out, cudamat* d_out, cudamat* dw_dense, cudamat* dw_diag, cudamat* db, bool init) {
  int numcases = s_in->size[0];
  int num_lstms = s_in->size[1] / 6;

  if (!init) { 
    cublasSgemm('t', 'n', 4 * num_lstms, num_lstms, numcases,
                1, d_out->data_device + numcases * num_lstms * 2, numcases,
                s_in->data_device, numcases,
                1, dw_dense->data_device, 4 * num_lstms);
    if (check_cublas_error())
      return CUBLAS_ERROR;
  }
  
  // Gradients for diagonal "peephole" weights.
  int shared_mem_size = 32 * sizeof(float);
  kLSTMOutp<<<num_lstms, 32, shared_mem_size>>>(
      s_in->data_device, s_out->data_device, d_out->data_device,
      dw_diag->data_device, db->data_device, numcases, num_lstms, init);
 
  if (checkCUDAError())
    return CUDA_ERROR;
  return 0;
}

int bn_bprop(cudamat* deriv, cudamat* input, cudamat* gamma, cudamat* mu,
             cudamat* sigma, cudamat* target, float scale_targets) {
  int height = deriv->size[0];
  int width  = deriv->size[1];
  if (input->size[0] != height || input->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (target->size[0] != height || target->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (gamma->size[0] != 1 || gamma->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (mu->size[0] != 1 || mu->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (sigma->size[0] != 1 || sigma->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  int shared_mem_size = 32 * sizeof(float);
  kBNBprop<<<width, 32, shared_mem_size>>> (
           deriv->data_device, input->data_device, gamma->data_device,
           mu->data_device, sigma->data_device, target->data_device, width,
           height, scale_targets);
  if (checkCUDAError())
    return CUDA_ERROR;
  return 0;
}

int bn_grad(cudamat* deriv, cudamat* input, cudamat* mu, cudamat* sigma,
            cudamat* dgamma, cudamat* dbeta) {
  int height = deriv->size[0];
  int width  = deriv->size[1];
  int shared_mem_size = 32 * sizeof(float);
  if (input->size[0] != height || input->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (mu->size[0] != 1 || mu->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (sigma->size[0] != 1 || sigma->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (dgamma->size[0] != 1 || dgamma->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (dbeta->size[0] != 1 || dbeta->size[1] != width)
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  kBNGrad<<<width, 32, shared_mem_size>>> (
           deriv->data_device, input->data_device,
           mu->data_device, sigma->data_device,
           dgamma->data_device, dbeta->data_device,
           width, height);
  if (checkCUDAError())
    return CUDA_ERROR;
  return 0;
}

// New LSTM kernels with data layout: cols = lstms, rows = batchsize, then timesteps.
int lstm_fprop2(cudamat* gates, cudamat* cell_prev, cudamat* cell, cudamat* output, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMFprop2<<<num_blocks, num_threads>>>(
      gates->data_device, cell_prev->data_device,
      cell->data_device, output->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_fprop2.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_fprop2_init(cudamat* gates, cudamat* cell, cudamat* output, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMFprop2Init<<<num_blocks, num_threads>>>(
      gates->data_device, cell->data_device, output->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_fprop2_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}


int lstm_bprop2(cudamat* gates, cudamat* gates_deriv, cudamat* cell_prev, cudamat* cell_prev_deriv,
                cudamat* cell, cudamat* cell_deriv, cudamat* output_deriv, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMBprop2<<<num_blocks, num_threads>>>(
      gates->data_device, gates_deriv->data_device,
      cell_prev->data_device, cell_prev_deriv->data_device,
      cell->data_device, cell_deriv->data_device,
      output_deriv->data_device, w->data_device,
      num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_bprop2.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_bprop2_init(cudamat* gates, cudamat* gates_deriv,
                     cudamat* cell, cudamat* cell_deriv, cudamat* output_deriv, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMBprop2Init<<<num_blocks, num_threads>>>(
      gates->data_device, gates_deriv->data_device,
      cell->data_device, cell_deriv->data_device,
      output_deriv->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_bprop2_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_outp2_init(cudamat* gates_deriv, cudamat* cell, cudamat* dw) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  kLSTMOutp2Init<<<num_lstms, 32, 32 * sizeof(float)>>>(
      gates_deriv->data_device, cell->data_device, dw->data_device, num_lstms,
      num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_outp2_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_outp2(cudamat* gates_deriv, cudamat* prev_cell, cudamat* cell, cudamat* dw) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  kLSTMOutp2<<<num_lstms, 32, 32 * sizeof(float)>>>(
      gates_deriv->data_device, prev_cell->data_device, cell->data_device,
      dw->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_outp2.\n");
      return CUDA_ERROR;
  }
  return 0;
}


int capsule_activation(cudamat* h_in, cudamat* h_out, cudamat* length, cudamat* bessel_ratio) {
  int capsule_size = h_in->size[0];
  int num_capsules = h_in->size[1];

  if (num_capsules != h_out->size[1] || capsule_size != h_out->size[0])
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (num_capsules != length->size[0] * length->size[1])
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (num_capsules != bessel_ratio->size[0] * bessel_ratio->size[1])
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  int shared_mem_size = 32 * sizeof(float) ;
  kCapsuleActivation<<<num_capsules, 32, shared_mem_size>>>(
      h_in->data_device, length->data_device, bessel_ratio->data_device,
      h_out->data_device, num_capsules, capsule_size);

  if (checkCUDAError()) {
      printf("Error capsule activation.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int capsule_derivative_of_activation(cudamat* d_out, cudamat* h_out, cudamat* length, cudamat* bessel_ratio, cudamat* d_in, float sparsity_cost, float sparsity_scale) {
  int capsule_size = d_out->size[0];
  int num_capsules = d_out->size[1];

  if (num_capsules != length->size[0] * length->size[1])
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (num_capsules != bessel_ratio->size[0] * bessel_ratio->size[1])
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (capsule_size != h_out->size[0] || num_capsules != h_out->size[1])
    return ERROR_INCOMPATIBLE_DIMENSIONS;
  if (capsule_size != d_in->size[0] || num_capsules != d_in->size[1])
    return ERROR_INCOMPATIBLE_DIMENSIONS;

  int shared_mem_size = 32 * sizeof(float) ;
  kBpropCapsuleActivation<<<num_capsules, 32, shared_mem_size>>>(
      d_out->data_device, h_out->data_device, length->data_device,
      bessel_ratio->data_device, d_in->data_device, sparsity_cost,
      sparsity_scale, num_capsules, capsule_size);

  if (checkCUDAError()) {
      printf("Error capsule derivative of activation.\n");
      return CUDA_ERROR;
  }
  return 0;
}

// Spatial LSTM kernels
int lstm_fprop_spatial_init(cudamat* gates, cudamat* cell, cudamat* output, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMFpropSpatialInit<<<num_blocks, num_threads>>>(
      gates->data_device, cell->data_device, output->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_fprop_spatial_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_fprop_spatial_row_init(cudamat* gates, cudamat* cell_prev_row, cudamat* cell, cudamat* output, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMFpropSpatialRowInit<<<num_blocks, num_threads>>>(
      gates->data_device, cell_prev_row->data_device, cell->data_device, output->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_fprop_spatial_row_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_fprop_spatial_col_init(cudamat* gates, cudamat* cell_prev_col, cudamat* cell, cudamat* output, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMFpropSpatialColInit<<<num_blocks, num_threads>>>(
      gates->data_device, cell_prev_col->data_device, cell->data_device, output->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_fprop_spatial_col_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_fprop_spatial(cudamat* gates, cudamat* cell_prev_row, cudamat* cell_prev_col, cudamat* cell, cudamat* output, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMFpropSpatial<<<num_blocks, num_threads>>>(
      gates->data_device, cell_prev_row->data_device,
      cell_prev_col->data_device, cell->data_device, output->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_fprop_spatial.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_bprop_spatial_init(cudamat* gates, cudamat* gates_deriv,
                     cudamat* cell, cudamat* cell_deriv, cudamat* output_deriv, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMBpropSpatialInit<<<num_blocks, num_threads>>>(
      gates->data_device, gates_deriv->data_device,
      cell->data_device, cell_deriv->data_device,
      output_deriv->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_bprop_spatial_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_bprop_spatial_row_init(cudamat* gates, cudamat* gates_deriv, cudamat* cell_prev_row, cudamat* cell_prev_row_deriv,
                     cudamat* cell, cudamat* cell_deriv, cudamat* output_deriv, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMBpropSpatialRowInit<<<num_blocks, num_threads>>>(
      gates->data_device, gates_deriv->data_device,
      cell_prev_row->data_device, cell_prev_row_deriv->data_device,
      cell->data_device, cell_deriv->data_device,
      output_deriv->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_bprop_spatial_row_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_bprop_spatial_col_init(cudamat* gates, cudamat* gates_deriv, cudamat* cell_prev_col, cudamat* cell_prev_col_deriv,
                     cudamat* cell, cudamat* cell_deriv, cudamat* output_deriv, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMBpropSpatialColInit<<<num_blocks, num_threads>>>(
      gates->data_device, gates_deriv->data_device,
      cell_prev_col->data_device, cell_prev_col_deriv->data_device,
      cell->data_device, cell_deriv->data_device,
      output_deriv->data_device,
      w->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_bprop_spatial_col_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_bprop_spatial(cudamat* gates, cudamat* gates_deriv, cudamat* cell_prev_row, cudamat* cell_prev_row_deriv, cudamat* cell_prev_col,
                cudamat* cell_prev_col_deriv, cudamat* cell, cudamat* cell_deriv, cudamat* output_deriv, cudamat* w) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  dim3 num_blocks(DIVUP(num_lstms, 32), num_cases);
  dim3 num_threads(32, 1);
  kLSTMBpropSpatial<<<num_blocks, num_threads>>>(
      gates->data_device, gates_deriv->data_device,
      cell_prev_row->data_device, cell_prev_row_deriv->data_device,
      cell_prev_col->data_device, cell_prev_col_deriv->data_device,
      cell->data_device, cell_deriv->data_device,
      output_deriv->data_device, w->data_device,
      num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_bprop_spatial.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_outp_spatial_init(cudamat* gates_deriv, cudamat* cell, cudamat* dw) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  kLSTMOutpSpatialInit<<<num_lstms, 32, 32 * sizeof(float)>>>(
      gates_deriv->data_device, cell->data_device, dw->data_device,
      num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_outp_spatial_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_outp_spatial_row_init(cudamat* gates_deriv, cudamat* prev_cell_row, cudamat* cell, cudamat* dw) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  kLSTMOutpSpatialRowInit<<<num_lstms, 32, 32 * sizeof(float)>>>(
      gates_deriv->data_device, prev_cell_row->data_device, cell->data_device,
      dw->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_outp_spatial_row_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_outp_spatial_col_init(cudamat* gates_deriv, cudamat* prev_cell_col, cudamat* cell, cudamat* dw) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  kLSTMOutpSpatialColInit<<<num_lstms, 32, 32 * sizeof(float)>>>(
      gates_deriv->data_device, prev_cell_col->data_device, cell->data_device,
      dw->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_outp_spatial_col_init.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int lstm_outp_spatial(cudamat* gates_deriv, cudamat* prev_cell_row, cudamat* prev_cell_col, cudamat* cell, cudamat* dw) {
  int num_cases = cell->size[1];
  int num_lstms = cell->size[0];

  kLSTMOutpSpatial<<<num_lstms, 32, 32 * sizeof(float)>>>(
      gates_deriv->data_device, prev_cell_row->data_device, prev_cell_col->data_device,
      cell->data_device, dw->data_device, num_lstms, num_cases);
  cudaDeviceSynchronize();

  if (checkCUDAError()) {
      printf("Error in lstm_outp_spatial.\n");
      return CUDA_ERROR;
  }
  return 0;
}

int get_glimpses_matrix_scan(cudamat* F_x, cudamat* F_y, int start_row, int start_col, int patch_side, int image_side, int num_cases) {
    dim3 num_blocks(DIVUP(patch_side*image_side, 32), num_cases);
    dim3 num_threads(32, 1);
    kGetGlimpsesMatrixScan<<<num_blocks, num_threads>>>(F_x->data_device, F_y->data_device, start_row, start_col, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_glimpses_matrix_scan.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_glimpses_matrix_scan_mr(cudamat* F_x, cudamat* F_y, int start_row, int start_col, int patch_side, int image_side, int num_cases) {
    dim3 num_blocks(DIVUP(patch_side*image_side, 32), num_cases);
    dim3 num_threads(32, 1);
    kGetGlimpsesMatrixScanMR<<<num_blocks, num_threads>>>(F_x->data_device, F_y->data_device, start_row, start_col, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_glimpses_matrix_scan_mr.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_glimpses_matrix_scan_mr3(cudamat* F_x, cudamat* F_y, int start_row, int start_col, int patch_side, int image_side, int num_cases) {
    dim3 num_blocks(DIVUP(patch_side*image_side, 32), num_cases);
    dim3 num_threads(32, 1);
    kGetGlimpsesMatrixScanMR3<<<num_blocks, num_threads>>>(F_x->data_device, F_y->data_device, start_row, start_col, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_glimpses_matrix_scan_mr3.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_glimpses_matrix(cudamat* F_x, cudamat* F_y, cudamat* para, int patch_side, int image_side) {
    int num_cases = para->size[1];

    dim3 num_blocks(DIVUP(patch_side*image_side, 32), num_cases);
    dim3 num_threads(32, 1);
    kGetGlimpsesMatrix<<<num_blocks, num_threads>>>(F_x->data_device, F_y->data_device, para->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_glimpses_matrix.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_glimpses_matrix_laplace(cudamat* F_x, cudamat* F_y, cudamat* para, int patch_side, int image_side) {
    int num_cases = para->size[1];

    dim3 num_blocks(DIVUP(patch_side*image_side, 32), num_cases);
    dim3 num_threads(32, 1);
    kGetGlimpsesMatrixLaplace<<<num_blocks, num_threads>>>(F_x->data_device, F_y->data_device, para->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_glimpses_matrix.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int normalize_glmatrix(cudamat* F_x, cudamat* F_y, int patch_side, int image_side) {
    int num_cases = F_x->size[1];

    dim3 num_blocks(DIVUP(patch_side, 32), num_cases);
    dim3 num_threads(32, 1);
    kNormalizeGlmatrix<<<num_blocks, num_threads>>>(F_x->data_device, F_y->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in normalize_glmatrix.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int apply_glmatrix(cudamat* patches, cudamat* F_axis, cudamat* para, cudamat* input_frame, int patch_side, int image_side) {
    int num_cases = input_frame->size[1];
    int patch_dim = patches->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);
    if (patch_dim == patch_side*image_side) {
        kApplyGlmatrixLeft<<<num_blocks, num_threads>>>(patches->data_device, F_axis->data_device, input_frame->data_device, patch_side, image_side, num_cases);
        cudaDeviceSynchronize();

        if (checkCUDAError()) {
            printf("Error in apply_glmatrix_left.\n");
            return CUDA_ERROR;
        }
    }
    else if (patch_dim == patch_side*patch_side) {
        kApplyGlmatrixRight<<<num_blocks, num_threads>>>(patches->data_device, F_axis->data_device, para->data_device, input_frame->data_device, patch_side, image_side, num_cases);
        cudaDeviceSynchronize();

        if (checkCUDAError()) {
            printf("Error in apply_glmatrix_right.\n");
            return CUDA_ERROR;
        }
    }
    else {
        printf("Error in apply_glmatrix!!!\n");
        return -1;
    }
    return 0;
}

int apply_glmatrix_hat(cudamat* patches, cudamat* F_axis, cudamat* para, cudamat* input_frame, int patch_side, int image_side) {
    int num_cases = input_frame->size[1];
    int patch_dim = patches->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);
    if (patch_dim == image_side*patch_side) {
        kApplyGlmatrixHatLeft<<<num_blocks, num_threads>>>(patches->data_device, F_axis->data_device, input_frame->data_device, patch_side, image_side, num_cases);
        cudaDeviceSynchronize();

        if (checkCUDAError()) {
            printf("Error in apply_glmatrix_left.\n");
            return CUDA_ERROR;
        }
    }
    else if (patch_dim == image_side*image_side) {
        kApplyGlmatrixHatRight<<<num_blocks, num_threads>>>(patches->data_device, F_axis->data_device, para->data_device, input_frame->data_device, patch_side, image_side, num_cases);
        cudaDeviceSynchronize();

        if (checkCUDAError()) {
            printf("Error in apply_glmatrix_right.\n");
            return CUDA_ERROR;
        }
    }
    else {
        printf("Error in apply_glmatrix!!!\n");
        return -1;
    }
    return 0;
}

int get_sampling_grid(cudamat* grid_x, cudamat* grid_y, cudamat* para, int patch_side, int image_side) {
    int num_cases = grid_x->size[1];
    int patch_dim = grid_x->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetSamplingGrid<<<num_blocks, num_threads>>>(grid_x->data_device, grid_y->data_device, para->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_sampling_grid.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_atten_grid(cudamat* grid_x, cudamat* grid_y, cudamat* para, int patch_side, int image_side) {
    int num_cases = grid_x->size[1];
    int patch_dim = grid_x->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetAttenGrid<<<num_blocks, num_threads>>>(grid_x->data_device, grid_y->data_device, para->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_atten_grid.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_atten_grid_trans(cudamat* grid_x, cudamat* grid_y, cudamat* para, int patch_side, int image_side) {
    int num_cases = grid_x->size[1];
    int patch_dim = grid_x->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetAttenGridTrans<<<num_blocks, num_threads>>>(grid_x->data_device, grid_y->data_device, para->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_atten_grid_trans.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int apply_sampling_grid(cudamat* patches, cudamat* grid_x, cudamat* grid_y, cudamat* input_frame, int patch_side, int image_side) {
    int num_cases = input_frame->size[1];
    int patch_dim = patches->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kApplySamplingGrid<<<num_blocks, num_threads>>>(patches->data_device, grid_x->data_device, grid_y->data_device, input_frame->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in apply_sampling_grid.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int apply_sampling_grid_feat(cudamat* patches, cudamat* grid_x, cudamat* grid_y, cudamat* input_map, int patch_side, int map_side) {
    int num_cases = input_map->size[1];
    int patch_dim = grid_x->size[0];
    int num_channel = patches->size[0] / patch_dim;

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kApplySamplingGridFeat<<<num_blocks, num_threads>>>(patches->data_device, grid_x->data_device, grid_y->data_device, input_map->data_device, patch_side, map_side, num_channel, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in apply_sampling_grid_feat.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_grid_derive_feat(cudamat* grid_x_deriv, cudamat* grid_y_deriv, cudamat* patch_deriv, cudamat* grid_x, cudamat* grid_y, cudamat* input_map, int patch_side, int map_side) {
    int num_cases = input_map->size[1];
    int patch_dim = grid_x->size[0];
    int num_channel = patch_deriv->size[0] / patch_dim;

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetGridDeriveFeat<<<num_blocks, num_threads>>>(grid_x_deriv->data_device, grid_y_deriv->data_device, patch_deriv->data_device, grid_x->data_device, grid_y->data_device, input_map->data_device, patch_side, map_side, num_channel, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_grid_derive_feat.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_grid_and_feat_derive(cudamat* grid_x_deriv, cudamat* grid_y_deriv, cudamat* feat_deriv, cudamat* patch_deriv, cudamat* grid_x, cudamat* grid_y, cudamat* input_map, int patch_side, int map_side) {
    int num_cases = input_map->size[1];
    int patch_dim = grid_x->size[0];
    int num_channel = patch_deriv->size[0] / patch_dim;

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetGridAndFeatDerive<<<num_blocks, num_threads>>>(grid_x_deriv->data_device, grid_y_deriv->data_device, feat_deriv->data_device, patch_deriv->data_device, grid_x->data_device, grid_y->data_device, input_map->data_device, patch_side, map_side, num_channel, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_grid_and_feat_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_grid_derive(cudamat* grid_x_deriv, cudamat* grid_y_deriv, cudamat* patch_deriv, cudamat* grid_x, cudamat* grid_y, cudamat* input_frame, int patch_side, int image_side) {
    int num_cases = input_frame->size[1];
    int patch_dim = grid_x->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetGridDerive<<<num_blocks, num_threads>>>(grid_x_deriv->data_device, grid_y_deriv->data_device, patch_deriv->data_device, grid_x->data_device, grid_y->data_device, input_frame->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_grid_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_para_affine_derive(cudamat* para_affine_deriv, cudamat* grid_x_deriv, cudamat* grid_y_deriv, int patch_side, int image_side) {
    int num_cases = grid_x_deriv->size[1];
    int patch_dim = grid_x_deriv->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetParaAffineDerive<<<num_blocks, num_threads>>>(para_affine_deriv->data_device, grid_x_deriv->data_device, grid_y_deriv->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_para_affine_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_para_atten_derive(cudamat* para_affine_deriv, cudamat* grid_x_deriv, cudamat* grid_y_deriv, int patch_side, int image_side) {
    int num_cases = grid_x_deriv->size[1];
    int patch_dim = grid_x_deriv->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetParaAttenDerive<<<num_blocks, num_threads>>>(para_affine_deriv->data_device, grid_x_deriv->data_device, grid_y_deriv->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_para_affine_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_para_atten_trans_derive(cudamat* para_affine_deriv, cudamat* grid_x_deriv, cudamat* grid_y_deriv, int patch_side, int image_side) {
    int num_cases = grid_x_deriv->size[1];
    int patch_dim = grid_x_deriv->size[0];

    dim3 num_blocks(DIVUP(patch_dim, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetParaAttenTransDerive<<<num_blocks, num_threads>>>(para_affine_deriv->data_device, grid_x_deriv->data_device, grid_y_deriv->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_para_affine_trans_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int sum_para_derive(cudamat* para_deriv, cudamat* para_grid_deriv, int patch_side) {
    int num_cases = para_deriv->size[1];
    int num_para = para_deriv->size[0];

    dim3 num_blocks(DIVUP(num_para, 32), num_cases);
    dim3 num_threads(32, 1);

    kSumParaDerive<<<num_blocks, num_threads>>>(para_deriv->data_device, para_grid_deriv->data_device, num_para, patch_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in sum_para_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int dis_para_derive(cudamat* para_grid_deriv, cudamat* para_deriv, int patch_side) {
    int num_cases = para_deriv->size[1];
    int num_para = para_deriv->size[0];

    dim3 num_blocks(DIVUP(num_para, 32), num_cases);
    dim3 num_threads(32, 1);

    kDisParaDerive<<<num_blocks, num_threads>>>(para_grid_deriv->data_device, para_deriv->data_device, num_para, patch_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in dis_para_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_para0123_derive(cudamat* para_xy_deriv, cudamat* F_x, cudamat* F_y, cudamat* para, int patch_side, int image_side) {
    int num_cases = para->size[1];

    dim3 num_blocks(DIVUP(patch_side*image_side, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetPara0123Derive<<<num_blocks, num_threads>>>(para_xy_deriv->data_device, F_x->data_device, F_y->data_device, para->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_para0123_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_para0123_derive_laplace(cudamat* para_xy_deriv, cudamat* F_x, cudamat* F_y, cudamat* para, int patch_side, int image_side) {
    int num_cases = para->size[1];

    dim3 num_blocks(DIVUP(patch_side*image_side, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetPara0123DeriveLaplace<<<num_blocks, num_threads>>>(para_xy_deriv->data_device, F_x->data_device, F_y->data_device, para->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_para0123_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

int get_output_patch_derive(cudamat* output_patch_deriv, cudamat* output_deriv, cudamat* F_x_hat, cudamat* F_y_hat, cudamat* para, int patch_side, int image_side) {
    int num_cases = output_patch_deriv->size[1];

    dim3 num_blocks(DIVUP(patch_side*patch_side, 32), num_cases);
    dim3 num_threads(32, 1);

    kGetOutputPatchDerive<<<num_blocks, num_threads>>>(output_patch_deriv->data_device, output_deriv->data_device, F_x_hat->data_device, F_y_hat->data_device, para->data_device, patch_side, image_side, num_cases);
    cudaDeviceSynchronize();

    if (checkCUDAError()) {
        printf("Error in get_output_patch_derive.\n");
        return CUDA_ERROR;
    }
    return 0;
}

#ifdef __cplusplus
}
#endif
