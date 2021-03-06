#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>

// Interleaved addressing with divergent branching
__global__ void reduce_kernel0(int *d_out, int *d_in)
{
    extern __shared__ int s_data[];

    // thread ID inside the block
    unsigned int tid = threadIdx.x;
    // global ID across all blocks
    unsigned int gid = blockIdx.x * blockDim.x + threadIdx.x;

    // Copy elements from global memoery into per-block shared memory
    s_data[tid] = d_in[gid];
    // Ensure all elements have been copied into shared memory
    __syncthreads();

    // s = 1, 2, 4, 8, ..... blockDim.x / 2
    for (unsigned int s = 1; s < blockDim.x; s <<= 1) {
        if (tid % (s << 1) == 0) {
            s_data[tid] += s_data[tid + s];
        }
        // Ensure all threads in the block finish add in this round
        __syncthreads();
    }

    // write the reduction sum back to the global memory
    if (tid == 0) {
        d_out[blockIdx.x] = s_data[0];
    }
}

// Interleaved addressing with bank conflicts
__global__ void reduce_kernel1(int *d_out, int *d_in)
{
    extern __shared__ int s_data[];

    // thread ID inside the block
    unsigned int tid = threadIdx.x;
    // global ID across all blocks
    unsigned int gid = blockIdx.x * blockDim.x + threadIdx.x;

    // Copy elements from global memoery into per-block shared memory
    s_data[tid] = d_in[gid];
    // Ensure all elements have been copied into shared memory
    __syncthreads();    

    // s = 1, 2, 4, 8, ..... blockDim.x / 2
    for (unsigned int s = 1; s < blockDim.x; s <<= 1) {
        int index = tid * s * 2;

        if (index + s < blockDim.x) {
            s_data[index] += s_data[index + s];
        }

        // Ensure all threads in the block finish add in this round
        __syncthreads();
    }

    if (tid == 0) {
        d_out[blockIdx.x] = s_data[0];
    }
}

// Sequential addressing
__global__ void reduce_kernel2(int *d_out, int *d_in)
{
    extern __shared__ int s_data[];

    // thread ID inside the block
    unsigned int tid = threadIdx.x;
    // global ID across all blocks
    unsigned int gid = blockIdx.x * blockDim.x + threadIdx.x;

    // Copy elements from global memoery into per-block shared memory
    s_data[tid] = d_in[gid];
    // Ensure all elements have been copied into shared memory
    __syncthreads();    

    // s = blockDim.x / 2, ....., 8, 4, 2, 1
    for (unsigned int s = (blockDim.x >> 1); s >= 1; s >>= 1) {
        if (tid < s) {
            s_data[tid] += s_data[tid + s];
        }
        // Ensure all threads in the block finish add in this round
        __syncthreads();
    }

    if (tid == 0) {
        d_out[blockIdx.x] = s_data[0];
    }
}

// First add during global load
__global__ void reduce_kernel3(int *d_out, int *d_in)
{
    extern __shared__ int s_data[];

    // thread ID inside the block
    unsigned int tid = threadIdx.x;
    // global ID across all blocks
    unsigned int gid = blockIdx.x * blockDim.x * 2 + threadIdx.x;

    // perform first level of reduction,
    // reading from global memory, writing to shared memory
    s_data[tid] = d_in[gid] + d_in[gid + blockDim.x];
    // Ensure all elements have been copied into shared memory
    __syncthreads();    

    // s = blockDim.x / 2, ....., 8, 4, 2, 1
    for (unsigned int s = (blockDim.x >> 1); s >= 1; s >>= 1) {
        if (tid < s) {
            s_data[tid] += s_data[tid + s];
        }
        // Ensure all threads in the block finish add in this round
        __syncthreads();
    }

    if (tid == 0) {
        d_out[blockIdx.x] = s_data[0];
    }    
}

inline bool is_power_of_2(int n)
{
    return ((n & (n - 1)) == 0);
}


// input: array (in host memory), array size, expected result, kernel function ID and iterations 
void reduce(int *h_in, int array_size, int expected_result, int kernel_id, int iters)
{
    // # of threads per block. It should be the power of two
    int threads = 1 << 10;
    // # of blocks in total. 
    int blocks = 1;
    // GPU memory pointers
    int *d_in, *d_intermediate, *d_out;
    // final result in host memory
    int h_out;

    if (!h_in || array_size <= 0 || !is_power_of_2(array_size))
        goto out;

    if (array_size > threads)
        blocks = array_size / threads;
    
    // allocate GPU memory
    if (cudaMalloc((void**) &d_in, array_size * sizeof(int)) != cudaSuccess
     || cudaMalloc((void**) &d_intermediate, blocks * sizeof(int)) != cudaSuccess
     || cudaMalloc((void**) &d_out, sizeof(int)) != cudaSuccess)
        goto out;
    

    // copy the input array from the host memory to the GPU memory
    cudaMemcpy(d_in, h_in, array_size * sizeof(int), cudaMemcpyHostToDevice);

    // run many times
    for (int i = 0; i < iters; i++) {
        switch (kernel_id) {
            // Interleaved addressing with divergent branching 
            case 0: 
                // first stage reduce
                reduce_kernel0<<<blocks, threads, threads * sizeof(int)>>>(d_intermediate, d_in);
                // second stage reduce    
                reduce_kernel0<<<1, blocks, blocks * sizeof(int)>>>(d_out, d_intermediate);
                break;
            // Interleaved addressing with bank conflicts
            case 1:
                reduce_kernel1<<<blocks, threads, threads * sizeof(int)>>>(d_intermediate, d_in);
                reduce_kernel1<<<1, blocks, blocks * sizeof(int)>>>(d_out, d_intermediate);
                break;  
            // Sequential addressing              
            case 2:
                reduce_kernel2<<<blocks, threads, threads * sizeof(int)>>>(d_intermediate, d_in);
                reduce_kernel2<<<1, blocks, blocks * sizeof(int)>>>(d_out, d_intermediate);
                break;
            // First add during global load
            case 3:
                reduce_kernel3<<<blocks, threads / 2 , threads / 2 * sizeof(int)>>>(d_intermediate, d_in);
                reduce_kernel3<<<1, blocks / 2, blocks / 2 * sizeof(int)>>>(d_out, d_intermediate);  
                break;              
            default:
                printf("Invalid kernel function ID %d\n", kernel_id);   
                goto out;      
        }
    }

    // copy the result from the GPU memory to the host memory
    cudaMemcpy(&h_out, d_out, sizeof(int), cudaMemcpyDeviceToHost);

    if (h_out != expected_result) {
        printf("Wrong result: %d (expected) %d (actual)\n", expected_result, h_out);
    }

out:
    // free GPU memory
    cudaFree(d_in);
    cudaFree(d_intermediate);
    cudaFree(d_out);
}

// generate a random integer in [min, max]
inline int random_range(int min, int max)
{
    if (min > max)
        return 0;
    else
        return min + rand() / (RAND_MAX / (max - min + 1) + 1);
}

int main(int argc, char **argv) 
{
    if (argc != 3) {
        printf("%s [kernel ID] [iterations]\n", argv[0]);
        exit(EXIT_FAILURE);
    }

    int kernel_id = atoi(argv[1]);
    int iters = atoi(argv[2]);
    if (iters <= 0 || kernel_id < 0) {
        printf("Invalid input\n");
        exit(EXIT_FAILURE);
    }

    const int ARRAY_SIZE = 1 << 20;
    int h_in[ARRAY_SIZE];
    int sum = 0;
    
    // initialize random number generator
    srand(time(NULL));
    int min = 0, max = 10;

    for (int i = 0; i < ARRAY_SIZE; i++) {
        // generate a random int in a range
        h_in[i] = random_range(min, max);
        sum += h_in[i];
    }

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);
    
    cudaEventRecord(start, 0);
    reduce(h_in, ARRAY_SIZE, sum, kernel_id, iters);
    cudaEventRecord(stop, 0);
    cudaEventSynchronize(stop);

    float elapsed_time;
    cudaEventElapsedTime(&elapsed_time, start, stop);    
    elapsed_time /= iters;      

    printf("Average time elapsed: %f ms\n", elapsed_time);

    return 0;
}