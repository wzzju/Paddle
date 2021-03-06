# Copyright (c) 2021 PaddlePaddle Authors. All Rights Reserved
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from __future__ import print_function

from paddle.fluid.layer_helper import LayerHelper
from paddle.fluid.framework import in_dygraph_mode
from paddle.fluid import core


def softmax_mask_fuse_upper_triangle(x):
    """
    Fuse softmax mask together without even give a mask.
    Under GPT model, the mask is always be a upper triangle
    so we can simply mask the upper triangle part of x to get the mask result
    :param x: the input x (rst of QK)
    :return: the result of softmax mask fuse (upper triangle)
    """
    if in_dygraph_mode():
        out = core.ops.fused_softmax_mask_upper_triangle(x)
        return out

    helper = LayerHelper('fused_softmax_mask_upper_triangle', **locals())

    out = helper.create_variable_for_type_inference(dtype=x.dtype)

    helper.append_op(
        type='fused_softmax_mask_upper_triangle',
        inputs={'X': [x]},
        outputs={'Out': [out]})
    return out
