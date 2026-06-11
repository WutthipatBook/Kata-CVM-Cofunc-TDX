FROM python:3.11-alpine3.17
RUN pip install boto3
RUN pip install numpy==1.26.4 pandas==2.2.3
RUN pip install requests
COPY /tools/template.py /func/main.py
COPY prewarm.py /func/prewarm.py
COPY execute.py /func/execute.py
