ARG BASE_NAME

FROM split_container_builder:latest as builder
FROM sc_js_binding_builder:latest as js_binding_builder
FROM libc_builder:latest as libc_builder

FROM $BASE_NAME
RUN sed -i 's#https\?://dl-cdn.alpinelinux.org/alpine#https://mirrors.tuna.tsinghua.edu.cn/alpine#g' /etc/apk/repositories
RUN apk add coreutils strace make util-linux
RUN apk add protobuf-c libnet libnl3
RUN apk add bash
COPY tools/__start.sh /tools/start.sh
COPY tools/__parallel.sh /tools/parallel.sh
COPY tools/wait.py /tools/wait.py
COPY --from=builder /runtime/runtime /bin/sc-runtime
COPY --from=js_binding_builder /js_binding/build/Release/binding.node /lib/sc_js_binding.node
COPY tools/py_binding /py_binding
COPY tools/lean_container /lean_container
RUN cd /py_binding && ./build.sh && rm -r /py_binding /lean_container
COPY --from=libc_builder /musl /musl
RUN cd /musl && make install
