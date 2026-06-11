FROM python:alpine3.17
RUN pip install --no-cache-dir --index-url https://pypi.org/simple textblob==0.17.1 nltk==3.8.1
RUN python -m textblob.download_corpora
RUN mkdir func
COPY /tools/template.py /func/main.py
COPY prewarm.py /func/prewarm.py
COPY execute.py /func/execute.py
