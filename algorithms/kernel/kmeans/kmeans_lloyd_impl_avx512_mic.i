/* file: kmeans_lloyd_impl_avx512_mic.i */
/*******************************************************************************
* Copyright 2014-2016 Intel Corporation
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
*******************************************************************************/

/*
//++
//  AVX512-MIC optimization of auxiliary functions used in Lloyd method
//  of K-means algorithm
//--
*/

template<> void * kmeansInitTask<double, avx512_mic>(int dim, int clNum, double * centroids,
                      services::SharedPtr<services::KernelErrorCollection> &_errors)
{
    struct task_t<double,avx512_mic> * t;
    t = (task_t<double,avx512_mic> *)daal::services::daal_malloc(sizeof(struct task_t<double,avx512_mic>));
    if(!t)
    {
        _errors->add(services::ErrorMemoryAllocationFailed);
        return 0;
    }

    t->dim       = dim;
    t->clNum     = clNum;
    t->cCenters  = centroids;
    t->max_block_size = 448;

    /* Allocate memory for all arrays inside TLS */
    t->tls_task = new daal::tls<tls_task_t<double, avx512_mic>*>( [=]()-> tls_task_t<double, avx512_mic>*
    {
        tls_task_t<double, avx512_mic>* tt = new tls_task_t<double, avx512_mic>;
        if(!tt)
        {
            _errors->add(services::ErrorMemoryAllocationFailed);
            return 0;
        }

        tt->mkl_buff = service_scalable_calloc<double,avx512_mic>(t->max_block_size*t->clNum);
        if(!tt->mkl_buff)
        {
            _errors->add(services::ErrorMemoryAllocationFailed);
            delete tt;
            return 0;
        }

        tt->cS1      = service_scalable_calloc<double,avx512_mic>(t->clNum*t->dim);
        if(!tt->cS1)
        {
            _errors->add(services::ErrorMemoryAllocationFailed);
            service_scalable_free<double,avx512_mic>(tt->mkl_buff);
            delete tt;
            return 0;
        }

        tt->cS0      = service_scalable_calloc<int,avx512_mic>(t->clNum);
        if(!tt->cS0)
        {
            service_scalable_free<double,avx512_mic>(tt->mkl_buff);
            service_scalable_free<double,avx512_mic>(tt->cS1);
            _errors->add(services::ErrorMemoryAllocationFailed);
            delete tt;
            return 0;
        }

        tt->goalFunc = (double)(0.0);

        return tt;
    } ); /* Allocate memory for all arrays inside TLS: end */

    if(!t->tls_task)
    {
        _errors->add(services::ErrorMemoryAllocationFailed);
        daal::services::daal_free(t);
        return 0;
    }

    t->clSq = service_calloc<double,avx512_mic>(clNum);
    if(!t->clSq)
    {
        _errors->add(services::ErrorMemoryAllocationFailed);
        daal::services::daal_free(t);
        return 0;
    }

    for(size_t k=0;k<clNum;k++)
    {
        for(size_t j=0;j<dim;j++)
        {
            t->clSq[k] += centroids[k*dim + j]*centroids[k*dim + j] * 0.5;
        }
    }

    void * task_id;
    *(size_t*)(&task_id) = (size_t)t;

    return task_id;
}

template<> void addNTToTaskThreadedDense<double, avx512_mic, 0>
(void * task_id, const NumericTable * ntData, double *catCoef, NumericTable * ntAssign )
{
    struct task_t<double,avx512_mic> * t  = static_cast<task_t<double,avx512_mic> *>(task_id);

    size_t n = ntData->getNumberOfRows();

    size_t blockSizeDeafult = t->max_block_size;

    size_t nBlocks = n / blockSizeDeafult;
    nBlocks += (nBlocks*blockSizeDeafult != n);

    daal::threader_for( nBlocks, nBlocks, [=](int k)
    {
        struct tls_task_t<double, avx512_mic> * tt = t->tls_task->local();
        size_t blockSize = blockSizeDeafult;
        if( k == nBlocks-1 )
        {
            blockSize = n - k*blockSizeDeafult;
        }

        BlockDescriptor<int> assignBlock;

        BlockMicroTable<double, readOnly,  avx512_mic> mtData( ntData );
        double* data;

        size_t p           = t->dim;
        size_t nClusters   = t->clNum;
        double* inClusters = t->cCenters;
        double* clustersSq = t->clSq;
        int*    cS0        = tt->cS0;
        double* cS1        = tt->cS1;
        double* trg        = &(tt->goalFunc);
        double* x_clusters = tt->mkl_buff;

        mtData.getBlockOfRows( k*blockSizeDeafult, blockSize, &data );

        int* assignments = 0;

        char transa = 't';
        char transb = 'n';
        MKL_INT _m = nClusters;
        MKL_INT _n = blockSize;
        MKL_INT _k = p;
        double alpha = 1.0;
        MKL_INT lda = p;
        MKL_INT ldy = p;
        double beta = 0.0;
        MKL_INT ldaty = nClusters;

        Blas<double, avx512_mic>::xxgemm(&transa, &transb, &_m, &_n, &_k, &alpha, inClusters,
            &lda, data, &ldy, &beta, x_clusters, &ldaty);

        for (size_t i = 0; i < blockSize; i++)
        {
            double minGoalVal = clustersSq[0] - x_clusters[i*nClusters];
            size_t minIdx = 0;
            int j;
            int n8 = nClusters & ~(8-1);
            __m512d  mMin  = _mm512_set1_pd(minGoalVal);

            /* Unrolled by 8 loop */
            for (j = 0; j < n8; j+=8)
            {
                  __m512d mSq;
                  __m512d mX;
                  __m512d mSub;
                  __m512d mCurMin;
                  double dCurMin;
                  unsigned int iCurIdx;
                  __mmask8 maskMin;

                  mSq        = _mm512_load_pd (&(clustersSq[j]));
                  mX         = _mm512_load_pd (&(x_clusters[i*nClusters + j]));
                  mSub       = _mm512_sub_pd(mSq,mX);
                  dCurMin    = _mm512_reduce_min_pd (mSub);
                  mCurMin    = _mm512_set1_pd(dCurMin);
                  mMin       = _mm512_min_pd (mMin, mCurMin);
                  maskMin    = _mm512_cmp_pd_mask(mMin, mSub, _CMP_EQ_UQ);
                  iCurIdx    = ((unsigned int)maskMin) | 0xffffff00;
                  iCurIdx    = _mm_tzcnt_32(iCurIdx);
                  minIdx     = (iCurIdx<8)?(j+iCurIdx):minIdx;
            }

            minGoalVal = *(double*)&mMin;

            /* Tail loop */
            for(;j<nClusters;j++)
            {
                if( minGoalVal > clustersSq[j] - x_clusters[i*nClusters + j] )
                {
                    minGoalVal = clustersSq[j] - x_clusters[i*nClusters + j];
                    minIdx = j;
                }
            }

            minGoalVal *= 2.0;

            #pragma vector always
            #pragma unroll(16)
            #pragma ivdep
            for (size_t j = 0; j < p; j++)
            {
                cS1[minIdx * p + j] += data[i*p + j];
                minGoalVal += data[ i*p + j ] * data[ i*p + j ];
            }

            *trg += minGoalVal;
            cS0[minIdx]++;

        } /* for (size_t i = 0; i < blockSize; i++) */

        mtData.release();

    } ); /* daal::threader_for( nBlocks, nBlocks, [=](int k) */
}

template<> void getNTAssignmentsThreaded <lloydDense, double, avx512_mic>
(void * task_id, const NumericTable * ntData, const NumericTable * ntAssign, double *catCoef )
{
    struct task_t<double,avx512_mic> * t  = static_cast<task_t<double,avx512_mic> *>(task_id);

    size_t n = ntData->getNumberOfRows();

    size_t blockSizeDeafult = t->max_block_size;

    size_t nBlocks = n / blockSizeDeafult;
    nBlocks += (nBlocks*blockSizeDeafult != n);

    daal::threader_for( nBlocks, nBlocks, [=](int k)
    {
        struct tls_task_t<double, avx512_mic> * tt = t->tls_task->local();
        size_t blockSize = blockSizeDeafult;
        if( k == nBlocks-1 )
        {
            blockSize = n - k*blockSizeDeafult;
        }

        BlockMicroTable<double, readOnly,  avx512_mic> mtData( ntData );
        BlockMicroTable<int   , writeOnly, avx512_mic> mtAssign( ntAssign );
        double* data;
        int*    assign;

        mtData  .getBlockOfRows( k*blockSizeDeafult, blockSize, &data   );
        mtAssign.getBlockOfRows( k*blockSizeDeafult, blockSize, &assign );

        size_t p           = t->dim;
        size_t nClusters   = t->clNum;
        double* inClusters = t->cCenters;
        double* clustersSq = t->clSq;
        double* x_clusters = tt->mkl_buff;

        char transa = 't';
        char transb = 'n';
        MKL_INT _m = nClusters;
        MKL_INT _n = blockSize;
        MKL_INT _k = p;
        double alpha = 1.0;
        MKL_INT lda = p;
        MKL_INT ldy = p;
        double beta = 0.0;
        MKL_INT ldaty = nClusters;

        Blas<double, avx512_mic>::xxgemm(&transa, &transb, &_m, &_n, &_k, &alpha, inClusters,
            &lda, data, &ldy, &beta, x_clusters, &ldaty);

        for (size_t i = 0; i < blockSize; i++)
        {
            double minGoalVal = clustersSq[0] - x_clusters[i*nClusters];
            size_t minIdx = 0;
            int j;
            int n8 = nClusters & ~(8-1);
            __m512d  mMin  = _mm512_set1_pd(minGoalVal);

            /* Unrolled by 8 loop */
            for (j = 0; j < n8; j+=8)
            {
                  __m512d mSq;
                  __m512d mX;
                  __m512d mSub;
                  __m512d mCurMin;
                  double dCurMin;
                  unsigned int iCurIdx;
                  __mmask8 maskMin;

                  mSq        = _mm512_load_pd (&(clustersSq[j]));
                  mX         = _mm512_load_pd (&(x_clusters[i*nClusters + j]));
                  mSub       = _mm512_sub_pd(mSq,mX);
                  dCurMin    = _mm512_reduce_min_pd (mSub);
                  mCurMin    = _mm512_set1_pd(dCurMin);
                  mMin       = _mm512_min_pd (mMin, mCurMin);
                  maskMin    = _mm512_cmp_pd_mask(mMin, mSub, _CMP_EQ_UQ);
                  iCurIdx    = ((unsigned int)maskMin) | 0xffffff00;
                  iCurIdx    = _mm_tzcnt_32(iCurIdx);
                  minIdx     = (iCurIdx<8)?(j+iCurIdx):minIdx;
            }

            minGoalVal = *(double*)&mMin;

            /* Tail loop */
            for(;j<nClusters;j++)
            {
                if( minGoalVal > clustersSq[j] - x_clusters[i*nClusters + j] )
                {
                    minGoalVal = clustersSq[j] - x_clusters[i*nClusters + j];
                    minIdx = j;
                }
            }

            assign[i] = minIdx;

        } /* for (size_t i = 0; i < blockSize; i++) */


        mtAssign.release();
        mtData.release();
    } );
}

template<> void kmeansClearClusters<double, avx512_mic>(void * task_id, double *goalFunc)
{
    int i, j;
    struct task_t<double,avx512_mic> * t = static_cast<task_t<double,avx512_mic> *>(task_id);

    if( t->clNum != 0)
    {
        t->clNum = 0;

        if( goalFunc!= 0 )
        {
            *goalFunc = (double)(0.0);

            t->tls_task->reduce( [=](tls_task_t<double, avx512_mic> *tt)-> void
            {
                (*goalFunc) += tt->goalFunc;
            } );
        }

        t->tls_task->reduce( [=](tls_task_t<double, avx512_mic>* tt)-> void
        {
            service_scalable_free<int,avx512_mic>( tt->cS0 );
            service_scalable_free<double,avx512_mic>( tt->cS1 );
            service_scalable_free<double,avx512_mic>( tt->mkl_buff );
        } );
        delete t->tls_task;

        service_free<double,avx512_mic>( t->clSq );

    }

    daal::services::daal_free(t);
}
