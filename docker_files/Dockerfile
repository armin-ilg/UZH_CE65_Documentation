#$#FROM ubuntu:latest
FROM rootproject/root:6.26.10-ubuntu22.04
LABEL maintainer = "Miljenko Suljic <miljenko.suljic@cern.ch>"

# Install basic build requirements
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Geneva
RUN apt-get update
RUN apt-get install -y curl cmake g++ gcc binutils git nano vim tmux

# Install ROOT dependencies
RUN apt-get install -y dpkg-dev libx11-dev libxpm-dev libxft-dev libxext-dev libssl-dev python3 python3-dev python3-pip python3-tk python-is-python3

# Install Corryvreckan dependencies
RUN apt-get install -y libeigen3-dev python3-lxml clang-format-12

# Install helpful Python packages
RUN pip3 install --upgrade pip && \
    pip3 install numpy matplotlib scipy pandas

# tqdm
RUN pip3 install tqdm


# EUDAQ2
ENV EUDAQ2PATH="/opt/eudaq2"
COPY debug_builds/eudaq2 ${EUDAQ2PATH}
RUN mkdir -p ${EUDAQ2PATH}/build && \
    cd ${EUDAQ2PATH}/build && \
    cmake -DEUDAQ_BUILD_STDEVENT_MONITOR=ON \
          -DUSER_ITS3_BUILD=ON \
          -DEUDAQ_BUILD_PYTHON=ON \
          .. && \
    make -j`grep -c processor /proc/cpuinfo` && \
    make install

# Corryvreckan
ENV CORRYPATH=/opt/corryvreckan
COPY debug_builds/corryvreckan ${CORRYPATH}
RUN mkdir -p ${CORRYPATH}/build && \
    cd ${CORRYPATH}/build && \
    cmake -DBUILD_EventLoaderEUDAQ2=ON \
          -Deudaq_DIR=${EUDAQ2PATH}/cmake \
          .. && \
    make -j`grep -c processor /proc/cpuinfo` && \
    make install


# Default command for starting the container, executed after the ENTRYPOINT
#ENV PATH "${CORRYPATH}/bin:${PATH}"
#ENV LD_LIBRARY_PATH "${EUDAQ2PATH}/lib:${LD_LIBRARY_PATH}"
#ENV PYTHONPATH "${EUDAQ2PATH}/lib:${PYTHONPATH}"
WORKDIR /local/
CMD ["bash"]
