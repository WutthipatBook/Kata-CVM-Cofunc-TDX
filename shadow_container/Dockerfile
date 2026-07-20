FROM alpine:3.17
RUN apk add build-base
RUN apk add linux-headers
RUN mkdir /runtime
COPY main.c /runtime/main.c
COPY config.h /runtime/config.h
COPY kvm_tdx.h /runtime/kvm_tdx.h
COPY kvm_sev.h /runtime/kvm_sev.h
COPY split_container.h /runtime/split_container.h
RUN gcc -Werror -o /runtime/runtime /runtime/main.c
