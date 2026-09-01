FROM quay.io/slopezpa/fedora-vgpu@sha256:d1fd35583d1c72bc7380bb977d5d51e70d70c77a2279a0412c2e6ac462f61f16 AS build

ARG LLAMA_CPP_VERSION
ARG LLAMA_CPP_BUILD_JOBS=2

RUN dnf install -y --setopt=install_weak_deps=False \
      cmake \
      gcc-c++ \
      git \
      glslc \
      spirv-headers-devel \
      vulkan-loader-devel \
    && dnf clean all
RUN git clone https://github.com/ggml-org/llama.cpp.git /src \
    && git -C /src checkout "$LLAMA_CPP_VERSION"
RUN cmake -S /src -B /src/build \
      -DBUILD_SHARED_LIBS=OFF \
      -DCMAKE_BUILD_TYPE=Release \
      -DGGML_CCACHE=OFF \
      -DGGML_VULKAN=ON \
      -DLLAMA_CURL=OFF \
    && cmake --build /src/build \
      --parallel "$LLAMA_CPP_BUILD_JOBS" \
      --target llama-cli llama-server

FROM quay.io/slopezpa/fedora-vgpu@sha256:d1fd35583d1c72bc7380bb977d5d51e70d70c77a2279a0412c2e6ac462f61f16

COPY --from=build /src/build/bin/llama-cli /usr/local/bin/llama-cli
COPY --from=build /src/build/bin/llama-server /usr/local/bin/llama-server

ENTRYPOINT []
