/* file: concat_layer_forward_impl.i */
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
//  Implementation of concat algorithm
//--
*/

#ifndef __CONCAT_LAYER_FORWARD_IMPL_I__
#define __CONCAT_LAYER_FORWARD_IMPL_I__

#include "service_micro_table.h"

using namespace daal::internal;
using namespace daal::services;
using namespace daal::data_management;

namespace daal
{
namespace algorithms
{
namespace neural_networks
{
namespace layers
{
namespace concat
{
namespace forward
{
namespace internal
{

template<typename algorithmFPType, Method method, CpuType cpu>
void ConcatKernel<algorithmFPType, method, cpu>::compute(const concat::forward::Input *input, const concat::Parameter *parameter,
                                                         concat::forward::Result *result)
{
    SharedPtr<Tensor> resultTable = result->get(layers::forward::value);
    size_t concatDimension = parameter->concatDimension;

    services::SharedPtr<LayerData> inputCollection = input->get(layers::forward::inputLayerData);
    size_t nInputs = inputCollection->size();

    int *dimsArray;
    BlockMicroTable<int, readOnly, cpu> inputDims((result->get(layers::concat::auxInputDimensions)).get());
    inputDims.getBlockOfRows(0, 1, &dimsArray);

    const services::Collection<size_t> &resDims = resultTable->getDimensions();
    size_t nResultRows = resDims[0];
    SubtensorDescriptor<algorithmFPType> resultBlock;
    resultTable->getSubtensor(0, 0, 0, nResultRows, writeOnly, resultBlock);
    algorithmFPType *resultArray = resultBlock.getPtr();

    size_t dimsSum = 0;
    for(size_t j = 0; j < nInputs; j++)
    {
        dimsSum += dimsArray[j];
    }

    size_t offsetBefore = 1;
    for(size_t j = 0; j < concatDimension; j++)
    {
        offsetBefore *= resDims[j];
    }

    size_t offsetAfter = 1;
    for(size_t j = concatDimension + 1; j < resDims.size(); j++)
    {
        offsetAfter *= resDims[j];
    }

    size_t sum = 0;
    for(size_t l = 0; l < nInputs; l++)
    {
        SharedPtr<Tensor> inputTable = input->get(layers::forward::inputLayerData, l);

        const services::Collection<size_t> &dims = inputTable->getDimensions();
        size_t nInputRows = dims[0];

        SubtensorDescriptor<algorithmFPType> inputBlock;
        inputTable->getSubtensor(0, 0, 0, nInputRows, readOnly, inputBlock);
        algorithmFPType *inputArray = inputBlock.getPtr();

        for(size_t i = 0; i < offsetBefore; i++)
        {

            for(size_t k = 0; k < dimsArray[l]; k++)
            {
                for(size_t j = 0; j < offsetAfter; j++)
                {
                    size_t inputIndex = (i * dimsArray[l] + k) * offsetAfter + j;

                    size_t outputIndex = (i * dimsSum + k + sum) * offsetAfter + j;

                    resultArray[outputIndex] = inputArray[inputIndex];
                }
            }
        }

        inputTable->releaseSubtensor(inputBlock);
        sum += dimsArray[l];
    }

    resultTable->releaseSubtensor(resultBlock);
    inputDims.release();
}

} // namespace internal
} // namespace forward
} // namespace concat
} // namespace layers
} // namespace neural_networks
} // namespace algorithms
} // namespace daal

#endif
