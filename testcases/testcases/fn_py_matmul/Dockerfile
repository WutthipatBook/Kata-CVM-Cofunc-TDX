FROM python:alpine3.17
RUN pip install numpy==1.26.4
RUN mkdir func
COPY /tools/template.py /func/main.py
COPY prewarm.py /func/prewarm.py
COPY execute.py /func/execute.py
