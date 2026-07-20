FROM python:3.11-alpine3.17
RUN pip install boto3
RUN pip install --extra-index-url https://alpine-wheels.github.io/index numpy pandas
RUN pip install requests
COPY /tools/template.py /func/main.py
COPY prewarm.py /func/prewarm.py
COPY execute.py /func/execute.py
