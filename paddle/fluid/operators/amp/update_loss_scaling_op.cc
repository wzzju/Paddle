/* Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include "paddle/fluid/operators/amp/update_loss_scaling_op.h"
#include <string>
#include <vector>
#include "paddle/fluid/framework/op_registry.h"

namespace paddle {
namespace operators {

class UpdateLossScalingOp : public framework::OperatorWithKernel {
 public:
  using framework::OperatorWithKernel::OperatorWithKernel;

  void InferShape(framework::InferShapeContext* ctx) const override {
    OP_INOUT_CHECK(ctx->HasInput("FoundInfinite"), "Input", "FoundInfinite",
                   "update_loss_scaling");
    OP_INOUT_CHECK(ctx->HasInput("PrevLossScaling"), "Input", "PrevLossScaling",
                   "update_loss_scaling");
    OP_INOUT_CHECK(ctx->HasInput("InGoodSteps"), "Input", "InGoodSteps",
                   "update_loss_scaling");
    OP_INOUT_CHECK(ctx->HasInput("InBadSteps"), "Input", "InBadSteps",
                   "update_loss_scaling");
    OP_INOUT_CHECK(ctx->HasOutput("LossScaling"), "Output", "LossScaling",
                   "update_loss_scaling");
    OP_INOUT_CHECK(ctx->HasOutput("OutGoodSteps"), "Output", "OutGoodSteps",
                   "update_loss_scaling");
    OP_INOUT_CHECK(ctx->HasOutput("OutBadSteps"), "Output", "OutBadSteps",
                   "update_loss_scaling");
    ctx->SetOutputDim("LossScaling", {1});
    ctx->SetOutputDim("OutGoodSteps", {1});
    ctx->SetOutputDim("OutBadSteps", {1});
  }

 protected:
  framework::OpKernelType GetExpectedKernelType(
      const framework::ExecutionContext& ctx) const override {
    return framework::OpKernelType(
        OperatorWithKernel::IndicateVarDataType(ctx, "PrevLossScaling"),
        ctx.device_context());
  }
};

class UpdateLossScalingOpMaker : public framework::OpProtoAndCheckerMaker {
 public:
  void Make() override {
    AddInput("FoundInfinite",
             "(Tensor) 1-dim tensor, contains a bool scalar, which indicates "
             "whether there is any infinite gradient.");
    AddInput("PrevLossScaling",
             "(Tensor) 1-dim tensor, previous loss scaling.");
    AddInput("InGoodSteps",
             "(Tensor) 1-dim tensor, accumulates good steps in which all "
             "gradients are finite.");
    AddInput("InBadSteps",
             "(Tensor) 1-dim tensor, accumulates bad steps in which some "
             "gradients are infinite.");
    AddOutput("LossScaling", "(Tensor) 1-dim tensor, updated loss scaling.");
    AddOutput("OutGoodSteps", "(Tensor) 1-dim tensor, pdated good steps.");
    AddOutput("OutBadSteps", "(Tensor) 1-dim tensor, updated bad steps.");
    AddAttr<int>("incr_every_n_steps",
                 "A value represents increasing loss scaling every n "
                 "consecutive steps with finite gradients.");
    AddAttr<int>("decr_every_n_nan_or_inf",
                 "A value represents decreasing loss scaling every n "
                 "accumulated steps with nan or inf gradients.");
    AddAttr<float>("incr_ratio",
                   "The multiplier to use when increasing the loss scaling.")
        .AddCustomChecker([](float incr_ratio) {
          PADDLE_ENFORCE_EQ(incr_ratio > 1.0f, true,
                            platform::errors::InvalidArgument(
                                "'incr_ratio' should be greater than 1, but "
                                "the received is %f",
                                incr_ratio));
        });
    AddAttr<float>(
        "decr_ratio",
        "The less-than-one-multiplier to use when decreasing loss scaling.")
        .AddCustomChecker([](float decr_ratio) {
          PADDLE_ENFORCE_EQ(decr_ratio > 0.0f && decr_ratio < 1.0f, true,
                            platform::errors::InvalidArgument(
                                "'incr_ratio' should be between 0 and 1, but "
                                "the received is %f",
                                decr_ratio));
        });
    AddComment(R"DOC(
Update loss scaling according to overall gradients. If all gradients is 
finite after incr_every_n_steps, loss scaling will increase by incr_ratio. 
Otherwise, loss scaling will decrease by decr_ratio after
decr_every_n_nan_or_inf steps and each step some gradients are infinite.

)DOC");
  }
};

template <typename T>
class UpdateLossScalingFunctor<platform::CPUDeviceContext, T> {
 public:
  void operator()(const platform::CPUDeviceContext& ctx,
                  const bool* found_inf_v, const T* pre_loss_scaling_v,
                  const int* good_in_v, const int* bad_in_v,
                  const int incr_every_n_steps,
                  const int decr_every_n_nan_or_inf, const float incr_ratio,
                  const float decr_ratio, T* updated_loss_scaling_v,
                  int* good_out_v, int* bad_out_v) {
    Update<T>(found_inf_v, pre_loss_scaling_v, good_in_v, bad_in_v,
              incr_every_n_steps, decr_every_n_nan_or_inf, incr_ratio,
              decr_ratio, updated_loss_scaling_v, good_out_v, bad_out_v);
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
using CPU = paddle::platform::CPUDeviceContext;

REGISTER_OPERATOR(
    update_loss_scaling, ops::UpdateLossScalingOp,
    ops::UpdateLossScalingOpMaker,
    paddle::framework::EmptyGradOpMaker<paddle::framework::OpDesc>,
    paddle::framework::EmptyGradOpMaker<paddle::imperative::OpBase>);

REGISTER_OP_CPU_KERNEL(update_loss_scaling,
                       ops::UpdateLossScalingKernel<CPU, float>,
                       ops::UpdateLossScalingKernel<CPU, double>);
