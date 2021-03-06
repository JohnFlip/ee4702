/// LSU EE 7700-2 (Spring 2013), GPU Microarchitecture
//

 /// Homework 4
 //
 // Assignment in: http://www.ece.lsu.edu/koppel/gp/2013/hw04.pdf
 //
 /// Your Name:


#include <pthread.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>
#include <ctype.h>
#include <time.h>
#include <new>
#include <cuda_runtime.h>

#define N 4

 /// CUDA API Error-Checking Wrapper
///
#define CE(call)                                                              \
 {                                                                            \
   const cudaError_t rv = call;                                               \
   if ( rv != cudaSuccess )                                                   \
     {                                                                        \
       printf("CUDA error %d, %s\n",rv,cudaGetErrorString(rv));               \
       exit(1);                                                               \
     }                                                                        \
 }

double
time_fp()
{
  struct timespec tp;
  clock_gettime(CLOCK_REALTIME,&tp);
  return ((double)tp.tv_sec)+((double)tp.tv_nsec) * 0.000000001;
}

// Make it easy to switch between float and double for vertex and matrix
// elements.
//
typedef float Elt_Type;

struct __align__(16) Vertex
{
  Elt_Type __align__(16) a[N];
};

struct __align__(16) V4 {
  Elt_Type x, y, z, w;
};

struct App
{
  int num_threads;
  Elt_Type matrix[N][N];
  int array_size;  // Number of vertices.
  Vertex *v_in, *v_out;
  Vertex *d_v_in, *d_v_out;
  V4 * d_v4_in;

  int reduction_method;

  Elt_Type *thd_sum;
  Elt_Type *d_thd_sum;
};

// In host address space.
App app;

// In device constant address space.
__constant__ App d_app;

#define BLOCK_SIZE_MAX 1024
__shared__ Elt_Type shared_sum[BLOCK_SIZE_MAX];
__shared__ Elt_Type wshared_sum[32];

__device__ void reduce_method_1(float mag_sq);
__device__ void reduce_method_2(float mag_sq);
__device__ void reduce_method_3(float mag_sq);
__device__ void reduce_method_4(float mag_sq);


// The entry point for the GPU code.
//
__global__ void
cuda_thread_start()
{
  // Compute an id number that will be in the range from 0 to num_threads-1.
  //
  const int tid = threadIdx.x + blockIdx.x * blockDim.x;

  // Compute element number to start at.
  //
  const int start = tid;
  const int stop = d_app.array_size;
  const int inc = d_app.num_threads;

  Elt_Type sum_sum_of_sq = 0;

  for ( int h=start; h<stop; h += inc )
    {
      V4 p2 = d_app.d_v4_in[h];
      Vertex p;
      p.a[0] = p2.x; p.a[1] = p2.y; p.a[2] = p2.z; p.a[3] = p2.w;
      Vertex q;
      for ( int i=0; i<N; i++ )
        {
          q.a[i] = 0;
          for ( int j=0; j<N; j++ ) q.a[i] += d_app.matrix[i][j] * p.a[j];
        }
      d_app.d_v_out[h] = q;

      //  Compute the magnitude squared of q and update "sum" variable.
      //
      Elt_Type sum_of_sq = 0;
      for ( int i=0; i<N; i++ ) sum_of_sq += q.a[i] * q.a[i];
      sum_sum_of_sq += sum_of_sq;
    }

  // Use the desired reduction method routine.
  //
  // The reduction routine finds the sum of sum_sum_of_sq over all
  // the threads in a block and writes it to global memory.
  //
  switch ( d_app.reduction_method ) {
  case 0:
    // Have the CPU perform reduction.
    d_app.d_thd_sum[tid] = sum_sum_of_sq;
    break;

  case 1: // One thread computes the sum.
    reduce_method_1(sum_sum_of_sq);
    break;

  case 2: // Use a reduction tree with a __syncthreads each iteration.
    reduce_method_2(sum_sum_of_sq);
    break;

  case 3: // To avoid syncs, use one block.
    reduce_method_3(sum_sum_of_sq);
    break;

  case 4: // Homework goes solution in this routine.
    reduce_method_4(sum_sum_of_sq); break;

    // Force an error if reduction method unknown.
  default:  d_app.d_thd_sum[threadIdx.x] = 0; break;
  }

}

__device__ void
reduce_method_1(float thd_sum)
{
  // One thread computes the sum.

  shared_sum[threadIdx.x] = thd_sum;  // Make sum available to thread 0.
  __syncthreads();

  if ( threadIdx.x != 0 ) return;

  Elt_Type our_sum = thd_sum;

  for ( int i=1; i<blockDim.x; i++ )
    our_sum += shared_sum[i];

  d_app.d_thd_sum[blockIdx.x] = our_sum;
}

__device__ void
reduce_method_2(float thd_sum)
{
  // Use a reduction tree.
  //
  // By using a complete tree reduction we perform the minimum
  // number of adds. That's the good news. The bad news is that
  // we need to synchronize each iteration.

  shared_sum[threadIdx.x] = thd_sum;  // Make sum available to other threads.
  Elt_Type our_sum = thd_sum;

  for ( int dist = blockDim.x >> 1;  dist;  dist >>= 1 )
    {
      __syncthreads();  // Wait for other threads to finish.
      if ( threadIdx.x < dist )
        {
          our_sum += shared_sum[ threadIdx.x + dist ];
          shared_sum[ threadIdx.x ] = our_sum;
        }
    }

  if ( threadIdx.x ) return;

  d_app.d_thd_sum[blockIdx.x] = our_sum;
}

__device__ void
reduce_method_3(float thd_sum)
{
  // A mixture of a linear sum and a tree reduction, chosen so
  // that only a single warp of threads participates.  Since only
  // a single warp is executing, no synchronizations are necessary
  // other than the one after the thread's initial sum is written.

  shared_sum[threadIdx.x] = thd_sum;  // Make sum available to other threads.
  Elt_Type our_sum = thd_sum;

  __syncthreads();

  // In the code below, only the first 32 threads do something useful.

  const int warp_size = 32;
  const int half_warp_size = warp_size >> 1;

  // Perform a linear sum.
  //
  // The first 32 threads each compute their own sum.
  //
  if ( threadIdx.x < warp_size )
    for ( int i = threadIdx.x + warp_size;  i < blockDim.x;  i += warp_size )
      our_sum += shared_sum[i];

  shared_sum[threadIdx.x] = our_sum;

  // Perform a tree reduction.
  //
  // The first 32 threads perform a tree reduction of the linear sums
  // found in the previous step.
  //
  if ( threadIdx.x < half_warp_size )
    for ( int dist = half_warp_size;  dist;  dist >>= 1 )
      if ( threadIdx.x < dist )
        {
          our_sum += shared_sum[ threadIdx.x + dist ];
          shared_sum[ threadIdx.x ] = our_sum;
        }

  if ( threadIdx.x ) return;

  d_app.d_thd_sum[blockIdx.x] = our_sum;
}

__device__ void
reduce_method_4(float thd_sum)
{
  /// HOMEWORK SOLUTION GOES HERE

}

void
print_gpu_info()
{
  // Get information about GPU and its ability to run CUDA.
  //
  int device_count;
  cudaGetDeviceCount(&device_count); // Get number of GPUs.
  if ( device_count == 0 )
    {
      fprintf(stderr,"No GPU found, exiting.\n");
      exit(1);
    }

  int dev = 0;
  CE(cudaGetDevice(&dev));
  printf("Using GPU %d\n",dev);

  cudaDeviceProp cuda_prop;  // Properties of cuda device (GPU, cuda version).

  /// Print information about the available GPUs.
  //
  {
    CE(cudaGetDeviceProperties(&cuda_prop,dev));
    printf
      ("GPU %d: %s @ %.2f GHz WITH %d MiB GLOBAL MEM\n",
       dev, cuda_prop.name, cuda_prop.clockRate/1e6,
       int(cuda_prop.totalGlobalMem >> 20));

    const int cc_per_mp =
      cuda_prop.major == 1 ? 8 :
      cuda_prop.major == 2 ? ( cuda_prop.minor == 0 ? 32 : 48 ) :
      cuda_prop.major == 3 ? 192 : 0;

    printf
      ("GPU %d: L2: %d kiB   MEM<->L2: %.1f GB/s\n",
       dev,
       cuda_prop.l2CacheSize,
       cuda_prop.memoryClockRate * 1000.0
       * ( cuda_prop.memoryBusWidth >> 3 )
       * 1e-9
       );

    printf
      ("GPU %d: CC: %d.%d  MP: %2d  CC/MP: %3d  TH/BL: %4d\n",
       dev, cuda_prop.major, cuda_prop.minor,
       cuda_prop.multiProcessorCount,
       cc_per_mp,
       cuda_prop.maxThreadsPerBlock
       );

    printf
      ("GPU %d: SHARED: %5d B  CONST: %5d B  # REGS: %5d\n",
       dev,
       int(cuda_prop.sharedMemPerBlock), int(cuda_prop.totalConstMem),
       cuda_prop.regsPerBlock
       );
  }

  cudaFuncAttributes cfa_prob1; // Properties of code to run on device.
  CE( cudaFuncGetAttributes(&cfa_prob1,cuda_thread_start) );

  // Print information about GPU kernel routine.
  //
  printf("\nCUDA Routine Resource Usage:\n");
  printf(" Our CUDA Thread: %6zd shared, %zd const, %zd loc, %d regs; "
         "%d max threads per block.\n",
         cfa_prob1.sharedSizeBytes,
         cfa_prob1.constSizeBytes,
         cfa_prob1.localSizeBytes,
         cfa_prob1.numRegs,
         cfa_prob1.maxThreadsPerBlock);
}

void*
pt_thread_start(void *arg)
{
  const int tid = (ptrdiff_t) arg;
  printf("Hello from %d\n",tid);
  const int elt_per_thread = app.array_size / app.num_threads;
  const int start = elt_per_thread * tid;
  const int stop = start + elt_per_thread;

  for ( int h=start; h<stop; h++ )
    {
      Vertex p = app.v_in[h];
      Vertex q;
      for ( int i=0; i<N; i++ )
        {
          q.a[i] = 0;
          for ( int j=0; j<N; j++ ) q.a[i] += app.matrix[i][j] * p.a[j];
        }
      app.v_out[h] = q;
    }

  return NULL;
}

int
main(int argc, char **argv)
{
  // Examine argument 1, reduction method to use.
  //
  app.reduction_method = argc < 2 ? 0 : atoi(argv[1]);

  // Examine argument 2, block count, if negative, use pthreads.
  //
  const int arg1_int = argc < 3 ? 32 : atoi(argv[2]);
  const bool use_pthreads = arg1_int < 0;
  const int num_blocks = abs(arg1_int);

  // Examine argument 3, number of threads per block.
  //
  const int thd_per_block = argc < 4 ? 1024 : atoi(argv[3]);
  app.num_threads = use_pthreads ? -arg1_int : num_blocks * thd_per_block;

  // Examine argument 4, size of array in MiB. Fractional values okay.
  //
  app.array_size = argc < 5 ? 1 << 20 : int( atof(argv[4]) * (1<<20) );

  const int sum_array_size =
    app.reduction_method ? num_blocks : app.num_threads;

  if ( app.num_threads <= 0 || app.array_size <= 0 )
    {
      printf("Usage: %s [ -NUM_PTHREADS | NUM_CUDA_BLOCKS ] [THD_PER_BLOCK] "
             "[DATA_SIZE_MiB] [REDUCTION_METHOD]\n",
             argv[0]);
      exit(1);
    }

  if ( !use_pthreads )
    print_gpu_info();

  const int array_size_bytes = app.array_size * sizeof(app.v_in[0]);

  // Allocate storage for CPU copy of data.
  //
  app.v_in = new Vertex[app.array_size];
  app.v_out = new Vertex[app.array_size];

  // Allocate storage for GPU copy of data.
  //
  CE( cudaMalloc( &app.d_v_in,  app.array_size * sizeof(Vertex) ) );
  CE( cudaMalloc( &app.d_v_out, app.array_size * sizeof(Vertex) ) );
  app.d_v4_in = (V4*) app.d_v_in;

  //  Allocate storage on CPU and GPU for the minimum magnitude (sq) and
  //  its index.
  //
  app.thd_sum = new Elt_Type[sum_array_size];
  CE( cudaMalloc( &app.d_thd_sum, sum_array_size * sizeof(Elt_Type) ) );

  // Initialize device memory to zeros. Helps catch bugs.
  //
  CE( cudaMemset( app.d_thd_sum, 0, sum_array_size*sizeof(Elt_Type) ) );

  printf
    ("\nPreparing for %d %s threads for %d vectors.  "
     "Reduction method %d.\n",
         app.num_threads,
         use_pthreads ? "CPU" : "GPU",
         app.array_size, app.reduction_method);

  // Initialize input array.
  //
  for ( int i=0; i<app.array_size; i++ )
    for ( int j=0; j<N; j++ ) app.v_in[i].a[j] = drand48();

  // Initialize transformation matrix.
  //
  for ( int i=0; i<N; i++ )
    for ( int j=0; j<N; j++ )
      app.matrix[i][j] = drand48();

  double elapsed_time_s = 86400; // Reassigned to minimum run time.

  if ( use_pthreads )
    {
      const double time_start = time_fp();

      // Allocate a structure to hold pthread thread ids.
      //
      pthread_t* const ptid = new pthread_t[app.num_threads];

      // Set up a pthread attribute, used for specifying options.
      //
      pthread_attr_t attr;
      pthread_attr_init(&attr);
      pthread_attr_setscope(&attr, PTHREAD_SCOPE_SYSTEM);

      // Launch the threads.
      //
      for ( int i=0; i<app.num_threads; i++ )
        pthread_create(&ptid[i], &attr, pt_thread_start, (void*)i);

      // Wait for each thread to finish.
      //
      for ( int i=0; i<app.num_threads; i++ )
        pthread_join( ptid[i], NULL );

      elapsed_time_s = time_fp() - time_start;
    }
  else
    {
      // Prepare events used for timing.
      //
      cudaEvent_t gpu_start_ce, gpu_stop_ce;
      CE(cudaEventCreate(&gpu_start_ce));
      CE(cudaEventCreate(&gpu_stop_ce));

      // Copy input array from CPU to GPU.
      //
      CE( cudaMemcpy
          ( app.d_v_in, app.v_in, array_size_bytes, cudaMemcpyHostToDevice ) );

      // Copy App structure to GPU.
      //
      CE( cudaMemcpyToSymbol
          ( d_app, &app, sizeof(app), 0, cudaMemcpyHostToDevice ) );

      // Launch kernel multiple times and keep track of the best time.

      const int num_reps = 5;
      for ( int r=0; r<num_reps; r++ )
        {
          // Measure execution time starting "now", which is after data
          // set to GPU.
          //
          CE(cudaEventRecord(gpu_start_ce,0));

          printf("Launching with %d blocks of %d threads ... ",
                 num_blocks, thd_per_block);

          // Tell CUDA to start our threads on the GPU.
          //
          cuda_thread_start<<<num_blocks,thd_per_block>>>();

          // Stop measuring execution time now, which is before is data
          // returned from GPU.
          //
          CE(cudaEventRecord(gpu_stop_ce,0));
          CE(cudaEventSynchronize(gpu_stop_ce));
          float cuda_time_ms = -1.1;
          CE(cudaEventElapsedTime(&cuda_time_ms,gpu_start_ce,gpu_stop_ce));

          const double this_elapsed_time_s = cuda_time_ms * 0.001;
          printf(" %11.3f µs\n", this_elapsed_time_s * 1e6 );

          elapsed_time_s = min(this_elapsed_time_s,elapsed_time_s);
        }
    }

  // Copy output array from GPU to CPU.
  //
  CE( cudaMemcpy
      ( app.v_out, app.d_v_out, array_size_bytes, cudaMemcpyDeviceToHost) );

  //  Copy back per-thread sums.
  //
  CE( cudaMemcpy
      ( app.thd_sum, app.d_thd_sum,
        sizeof(Elt_Type) * sum_array_size, cudaMemcpyDeviceToHost) );

  // Find the sum of each thread or block's sum.
  //
  double grand_sum = app.thd_sum[0];
  for ( int i=1; i<sum_array_size; i++ )
    grand_sum += app.thd_sum[i];

  const double data_size = app.array_size * sizeof(Vertex) * 2;
  const double fp_op_count = app.array_size * ( 2 * N * N - N  );

  printf("Elapsed time for %d threads and %d elements is %.3f µs\n",
         app.num_threads, app.array_size, 1e6 * elapsed_time_s);
  printf("Rate %.3f GFLOPS,  %.3f GB/s\n",
         1e-9 * fp_op_count / elapsed_time_s,
         1e-9 * data_size / elapsed_time_s);

  {
    // Compute correct answer.
    double cpu_grand_sum = 0;

    for ( int h=0; h<app.array_size; h++ )
      {
        Vertex p = app.v_in[h];
        Vertex q;
        for ( int i=0; i<N; i++ )
          {
            q.a[i] = 0;
            for ( int j=0; j<N; j++ ) q.a[i] += app.matrix[i][j] * p.a[j];
          }
        Elt_Type sos = 0; for(int i=0; i<N; i++ ) sos+= q.a[i]*q.a[i];
        cpu_grand_sum += sos;
      }
    Elt_Type diff = fabs(grand_sum-cpu_grand_sum) / app.array_size;
    printf
      ("\nSum is %s,  %.1f %s %.1f (correct)\n",
       diff < 1e-5 ? "correct" : "**wrong**",
       grand_sum,
       grand_sum == cpu_grand_sum ? "==" : diff < 1e-5 ? "~" : "!=",
       cpu_grand_sum
       );

  }
}
