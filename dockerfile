FROM python:latest

COPY requirements.txt /

RUN pip install -r /requirements.txt
RUN apt-get update && apt-get install sshpass

CMD ["ansible-playbook", "--help"]