FROM nvidia/cuda:10.2-runtime-ubuntu18.04

WORKDIR /app
COPY ./ /app
RUN apt-get update && apt-get install -y libglfw3 libsdl2-dev

CMD ["bash", "start.sh"]