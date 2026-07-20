FROM python:alpine3.17
RUN pip install minio squiggle==0.3.1
RUN mkdir func
COPY /tools/template.py /func/main.py
COPY prewarm.py /func/prewarm.py
COPY execute.py /func/execute.py
COPY storage.py /func/storage.py
