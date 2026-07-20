FROM python:3.11-alpine3.17
RUN pip install boto3
RUN pip install --extra-index-url https://alpine-wheels.github.io/index numpy pandas
COPY main.py /func/main.py
