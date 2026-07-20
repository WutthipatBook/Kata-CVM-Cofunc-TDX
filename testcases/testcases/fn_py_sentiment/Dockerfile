FROM python:alpine3.17
ENV HTTPS_PROXY="http://ipads:ipads123@202.120.40.82:11235"
ENV HTTP_PROXY="http://ipads:ipads123@202.120.40.82:11235"
RUN pip install textblob
RUN python -m textblob.download_corpora
ENV HTTPS_PROXY=""
ENV HTTP_PROXY=""
RUN mkdir func
COPY /tools/template.py /func/main.py
COPY prewarm.py /func/prewarm.py
COPY execute.py /func/execute.py
