FROM python:alpine3.17
RUN pip install --extra-index-url https://alpine-wheels.github.io/index numpy
RUN mkdir func
COPY /tools/template.py /func/main.py
COPY prewarm.py /func/prewarm.py
COPY execute.py /func/execute.py
