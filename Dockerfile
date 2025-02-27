FROM ubuntu:latest AS build


RUN apt update && apt install cmake git clang zlib1g zlib1g-dev libllvm18 llvm llvm-dev llvm-runtime liblld-dev liblld-18 libpolly-18-dev -y

RUN git clone https://github.com/c3lang/c3c && \
    cd c3c && \
    git checkout 855be9288121d0f7a67d277f7bbbbf57fbfa2597 && \
    mkdir build && \
    cd build && \
    cmake .. && \
    cmake --build . && \
    chmod +x c3c && \
    cp c3c /usr/local/bin/c3c && \
    cp -r lib /usr/local/bin/lib 



RUN apt install nodejs npm -y

WORKDIR /app

COPY package.json package.json
COPY package-lock.json package-lock.json
RUN npm install


COPY . .
RUN npm run build

FROM node:latest AS run

WORKDIR /app

COPY --from=build /lib/x86_64-linux-gnu /lib/x86_64-linux-gnu 
COPY --from=build /app . 

RUN npm i

COPY --from=build /app/build/server build/server

ENTRYPOINT [ "npm", "run", "serve" ]
