#include "Octree.cuh"

__constant__ int3 coordPlacementIdentity[8] = {
  {-1,-1,-1},
  {-1,-1,1},
  {-1,1,-1},
  {-1,1,1},
  {1,-1,-1},
  {1,-1,1},
  {1,1,-1},
  {1,1,1}
};

__constant__ int2 vertexEdgeIdentity[12] = {
  {0,1},
  {0,2},
  {1,3},
  {2,3},
  {0,4},
  {1,5},
  {2,6},
  {3,7},
  {4,5},
  {4,6},
  {5,7},
  {6,7}
};

__constant__ int4 vertexFaceIdentity[6] = {
  {0,1,2,3},
  {0,1,4,5},
  {0,2,4,6},
  {1,3,5,7},
  {2,3,6,7},
  {4,5,6,7}
};

__constant__ int4 edgeFaceIdentity[6] = {
  {0,1,2,3},
  {0,4,5,8},
  {1,4,6,9},
  {2,5,7,10},
  {3,6,7,11},
  {8,9,10,11}
};

__device__ __host__ Vertex::Vertex(){
  for(int i = 0; i < 8; ++i){
    this->nodes[i] = -1;
  }
  this->depth = -1;
  this->coord = {0.0f,0.0f,0.0f};
  this->color = {0,0,0};
}

__device__ __host__ Edge::Edge(){
  for(int i = 0; i < 4; ++i){
    this->nodes[i] = -1;
  }
  this->depth = -1;
  this->v1 = -1;
  this->v2 = -1;
  this->color = {0,0,0};

}

__device__ __host__ Face::Face(){
  this->nodes[0] = -1;
  this->nodes[1] = -1;
  this->depth = -1;
  this->e1 = -1;
  this->e2 = -1;
  this->e3 = -1;
  this->e4 = -1;
  this->color = {0,0,0};

}

__device__ __host__ Node::Node(){
  this->pointIndex = -1;
  this->center = {0.0f,0.0f,0.0f};
  this->color = {0,0,0};
  this->key = 0;
  this->width = 0.0f;
  this->numPoints = 0;
  this->parent = -1;
  this->depth = -1;
  this->numFinestChildren = 0;
  this->finestChildIndex = -1;
  for(int i = 0; i < 27; ++i){
    if(i < 6){
      this->faces[i] = -1;
    }
    if(i < 8){
      this->children[i] = -1;
      this->vertices[i] = -1;
    }
    if(i < 12){
      this->edges[i] = -1;
    }
    this->neighbors[i] = -1;
  }
}

__device__ __host__ float3 getVoidCenter(const Node &node, int neighbor){
  float3 center = node.center;
  center.x += node.width*((neighbor/9) - 1);
  center.y += node.width*(((neighbor%9)/3) - 1);
  center.z += node.width*((neighbor%3) - 1);
  return center;
}
__device__ __host__ float3 getVoidChildCenter(const Node &parent, int child){
  float3 center = parent.center;
  float dist = parent.width/4;
  if((1 << 2) & child) center.x += dist;
  if((1 << 1) & child) center.y += dist;
  if(1 & child) center.z += dist;
  return center;
}

__device__ __forceinline__ int floatToOrderedInt(float floatVal){
 int intVal = __float_as_int( floatVal );
 return (intVal >= 0 ) ? intVal : intVal ^ 0x7FFFFFFF;
}
__device__ __forceinline__ float orderedIntToFloat(int intVal){
 return __int_as_float( (intVal >= 0) ? intVal : intVal ^ 0x7FFFFFFF);
}
__device__ __host__ void printBits(size_t const size, void const * const ptr){
  unsigned char *b = (unsigned char*) ptr;
  unsigned char byte;
  int i, j;
  printf("bits - ");
  for (i=size-1;i>=0;i--){
    for (j=7;j>=0;j--){
      byte = (b[i] >> j) & 1;
      printf("%u", byte);
    }
  }
  printf("\n");
}
__global__ void getNodeKeys(Sphere* spheres, float3* nodeCenters, int* nodeKeys, float3 c, float W, int numPoints, int D){
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  if(globalID < numPoints){
    float x = spheres[globalID].center.x;
    float y = spheres[globalID].center.y;
    float z = spheres[globalID].center.z;
    int key = 0;
    int depth = 1;
    W /= 2.0f;
    float3 center = c;
    while(depth <= D){
      W /= 2.0f;
      if(x < center.x){
        key <<= 1;
        center.x -= W;
      }
      else{
        key = (key << 1) + 1;
        center.x += W;
      }
      if(y < center.y){
        key <<= 1;
        center.y -= W;
      }
      else{
        key = (key << 1) + 1;
        center.y += W;
      }
      if(z < center.z){
        key <<= 1;
        center.z -= W;
      }
      else{
        key = (key << 1) + 1;
        center.z += W;
      }
      depth++;
    }
    nodeKeys[globalID] = key;
    nodeCenters[globalID] = center;
    //printf("%f,%f,%f\n",c.x,c.y,c.z);

  }
}

//createFinalNodeArray kernels
__global__ void findAllNodes(int numUniqueNodes, int* nodeNumbers, Node* uniqueNodes){
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  int tempCurrentKey = 0;
  int tempPrevKey = 0;
  if(globalID < numUniqueNodes){
    if(globalID == 0){
      nodeNumbers[globalID] = 0;
      return;
    }

    tempCurrentKey = uniqueNodes[globalID].key>>3;
    tempPrevKey = uniqueNodes[globalID - 1].key>>3;
    if(tempPrevKey == tempCurrentKey){
      nodeNumbers[globalID] = 0;
    }
    else{
      nodeNumbers[globalID] = 8;
    }
  }
}
void calculateNodeAddresses(dim3 grid, dim3 block, int numUniqueNodes, Node* uniqueNodes_device, int* nodeAddresses_device, int* nodeNumbers_device){
  findAllNodes<<<grid,block>>>(numUniqueNodes, nodeNumbers_device, uniqueNodes_device);
  cudaDeviceSynchronize();
  CudaCheckError();
  thrust::device_ptr<int> nN(nodeNumbers_device);
  thrust::device_ptr<int> nA(nodeAddresses_device);
  thrust::inclusive_scan(nN, nN + numUniqueNodes, nA);

}
__global__ void fillBlankNodeArray(Node* uniqueNodes, int* nodeNumbers, int* nodeAddresses, Node* outputNodeArray, int numUniqueNodes, int currentDepth, float totalWidth){
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  int address = 0;
  if(currentDepth != 0 && globalID < numUniqueNodes && (globalID == 0 || nodeNumbers[globalID] == 8)){
    int siblingKey = uniqueNodes[globalID].key;
    uchar3 color = uniqueNodes[globalID].color;
    siblingKey &= 0xfffffff8;//will clear last 3 bits
    for(int i = 0; i < 8; ++i){
      address = nodeAddresses[globalID] + i;
      outputNodeArray[address] = Node();
      outputNodeArray[address].color = color;
      outputNodeArray[address].depth = currentDepth;
      outputNodeArray[address].key = siblingKey + i;
    }
  }
  else if(currentDepth == 0){
    address = nodeAddresses[0];
    outputNodeArray[address] = Node();
    outputNodeArray[address].color = {255,255,255};
    outputNodeArray[address].depth = currentDepth;
    outputNodeArray[address].key = 0;
  }
}
__global__ void fillFinestNodeArrayWithUniques(Node* uniqueNodes, int* nodeAddresses, Node* outputNodeArray, int numUniqueNodes, unsigned int* pointNodeIndex){
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  int address = 0;
  int currentDKey = 0;
  if(globalID < numUniqueNodes){
    currentDKey = (uniqueNodes[globalID].key&(0x00000007));//will clear all but last 3 bits
    address = nodeAddresses[globalID] + currentDKey;
    for(int i = uniqueNodes[globalID].pointIndex; i < uniqueNodes[globalID].numPoints + uniqueNodes[globalID].pointIndex; ++i){
      pointNodeIndex[i] = address;
    }
    outputNodeArray[address].key = uniqueNodes[globalID].key;
    outputNodeArray[address].depth = uniqueNodes[globalID].depth;
    outputNodeArray[address].center = uniqueNodes[globalID].center;
    outputNodeArray[address].color = uniqueNodes[globalID].color;
    outputNodeArray[address].pointIndex = uniqueNodes[globalID].pointIndex;
    outputNodeArray[address].numPoints = uniqueNodes[globalID].numPoints;
    outputNodeArray[address].finestChildIndex = address;//itself
    outputNodeArray[address].numFinestChildren = 1;//itself
  }
}
__global__ void fillNodeArrayWithUniques(Node* uniqueNodes, int* nodeAddresses, Node* outputNodeArray, Node* childNodeArray,int numUniqueNodes){
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  int address = 0;
  int currentDKey = 0;
  if(globalID < numUniqueNodes){
    currentDKey = (uniqueNodes[globalID].key&(0x00000007));//will clear all but last 3 bits
    address = nodeAddresses[globalID] + currentDKey;
    for(int i = 0; i < 8; ++i){
      outputNodeArray[address].children[i] = uniqueNodes[globalID].children[i];
      childNodeArray[uniqueNodes[globalID].children[i]].parent = address;
    }
    outputNodeArray[address].key = uniqueNodes[globalID].key;
    outputNodeArray[address].depth = uniqueNodes[globalID].depth;
    outputNodeArray[address].center = uniqueNodes[globalID].center;
    outputNodeArray[address].color = uniqueNodes[globalID].color;
    outputNodeArray[address].pointIndex = uniqueNodes[globalID].pointIndex;
    outputNodeArray[address].numPoints = uniqueNodes[globalID].numPoints;
    outputNodeArray[address].finestChildIndex = uniqueNodes[globalID].finestChildIndex;
    outputNodeArray[address].numFinestChildren = uniqueNodes[globalID].numFinestChildren;
  }
}
//TODO try and optimize
__global__ void generateParentalUniqueNodes(Node* uniqueNodes, Node* nodeArrayD, int numNodesAtDepth, float totalWidth){
  int numUniqueNodesAtParentDepth = numNodesAtDepth / 8;
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  int nodeArrayIndex = globalID*8;
  if(globalID < numUniqueNodesAtParentDepth){
    uniqueNodes[globalID] = Node();//may not be necessary
    int firstUniqueChild = -1;
    bool childIsUnique[8] = {false};
    for(int i = 0; i < 8; ++i){
      if(nodeArrayD[nodeArrayIndex + i].pointIndex != -1){
        if(firstUniqueChild == -1){
          firstUniqueChild = i;
        }
        childIsUnique[i] = true;
      }
    }
    uniqueNodes[globalID].key = (nodeArrayD[nodeArrayIndex + firstUniqueChild].key>>3);
    uniqueNodes[globalID].pointIndex = nodeArrayD[nodeArrayIndex + firstUniqueChild].pointIndex;
    int depth =  nodeArrayD[nodeArrayIndex + firstUniqueChild].depth;
    uniqueNodes[globalID].depth = depth - 1;
    //should be the lowest index on the lowest child
    uniqueNodes[globalID].finestChildIndex = nodeArrayD[nodeArrayIndex + firstUniqueChild].finestChildIndex;

    float3 center = {0.0f,0.0f,0.0f};
    float widthOfNode = totalWidth/powf(2,depth);
    center.x = nodeArrayD[nodeArrayIndex + firstUniqueChild].center.x - (widthOfNode*0.5*coordPlacementIdentity[firstUniqueChild].x);
    center.y = nodeArrayD[nodeArrayIndex + firstUniqueChild].center.y - (widthOfNode*0.5*coordPlacementIdentity[firstUniqueChild].y);
    center.z = nodeArrayD[nodeArrayIndex + firstUniqueChild].center.z - (widthOfNode*0.5*coordPlacementIdentity[firstUniqueChild].z);
    uniqueNodes[globalID].center = center;

    for(int i = 0; i < 8; ++i){
      if(childIsUnique[i]){
        uniqueNodes[globalID].numPoints += nodeArrayD[nodeArrayIndex + i].numPoints;
        uniqueNodes[globalID].numFinestChildren += nodeArrayD[nodeArrayIndex + i].numFinestChildren;
      }
      else{
        nodeArrayD[nodeArrayIndex + i].center.x = center.x + (widthOfNode*0.5*coordPlacementIdentity[i].x);
        nodeArrayD[nodeArrayIndex + i].center.y = center.y + (widthOfNode*0.5*coordPlacementIdentity[i].y);
        nodeArrayD[nodeArrayIndex + i].center.z = center.z + (widthOfNode*0.5*coordPlacementIdentity[i].z);
      }
      uniqueNodes[globalID].children[i] = nodeArrayIndex + i;
      nodeArrayD[nodeArrayIndex + i].width = widthOfNode;
    }
  }
}
__global__ void computeNeighboringNodes(Node* nodeArray, int numNodes, int depthIndex,int* parentLUT, int* childLUT, int childDepthIndex){
  int blockID = blockIdx.y * gridDim.x + blockIdx.x;
  if(blockID < numNodes){
    int neighborParentIndex = 0;
    nodeArray[blockID + depthIndex].neighbors[13] = blockID + depthIndex;
    __syncthreads();//threads wait until all other threads have finished above operations
    if(nodeArray[blockID + depthIndex].parent != -1){
      int parentIndex = nodeArray[blockID + depthIndex].parent + depthIndex + numNodes;
      int depthKey = nodeArray[blockID + depthIndex].key&(0x00000007);//will clear all but last 3 bits
      int lutIndexHelper = (depthKey*27) + threadIdx.x;
      int parentLUTIndex = parentLUT[lutIndexHelper];
      int childLUTIndex = childLUT[lutIndexHelper];
      neighborParentIndex = nodeArray[parentIndex].neighbors[parentLUTIndex];
      if(neighborParentIndex != -1){
        nodeArray[blockID + depthIndex].neighbors[threadIdx.x] = nodeArray[neighborParentIndex].children[childLUTIndex];
      }
    }
    __syncthreads();//index updates
    //doing this mostly to prevent memcpy overhead
    if(childDepthIndex != -1 && threadIdx.x < 8 &&
      nodeArray[blockID + depthIndex].children[threadIdx.x] != -1){
      nodeArray[blockID + depthIndex].children[threadIdx.x] += childDepthIndex;
    }
    if(nodeArray[blockID + depthIndex].parent != -1 && threadIdx.x == 0){
      nodeArray[blockID + depthIndex].parent += depthIndex + numNodes;
    }
    else if(threadIdx.x == 0){//this means you are at root
      nodeArray[blockID + depthIndex].width = 2*nodeArray[nodeArray[blockID + depthIndex].children[0]].width;

    }
  }
}

__global__ void findNormalNeighborsAndComputeCMatrix(int numNodesAtDepth, int depthIndex, int maxNeighbors, Node* nodeArray, float3* points, float* cMatrix, int* neighborIndices, int* numNeighbors){
  int blockID = blockIdx.y * gridDim.x + blockIdx.x;
  if(blockID < numNodesAtDepth){
    float3 centroid = {0.0f,0.0f,0.0f};
    int n = 0;
    int regDepthIndex = depthIndex;
    int numPointsInNode = nodeArray[blockID + regDepthIndex].numPoints;
    int neighbor = -1;
    int regMaxNeighbors = maxNeighbors;
    int regPointIndex = nodeArray[blockID + regDepthIndex].pointIndex;
    float3 coord = {0.0f,0.0f,0.0f};
    float3 neighborCoord = {0.0f,0.0f,0.0f};
    float currentDistanceSq = 0.0f;
    float largestDistanceSq = 0.0f;
    int indexOfFurthestNeighbor = -1;
    int regNNPointIndex = 0;
    int numPointsInNeighbor = 0;
    float* distanceSq = new float[regMaxNeighbors];
    for(int threadID = threadIdx.x; threadID < numPointsInNode; threadID += blockDim.x){
      n = 0;
      coord = points[regPointIndex + threadID];
      currentDistanceSq = 0.0f;
      largestDistanceSq = 0.0f;
      indexOfFurthestNeighbor = -1;
      regNNPointIndex = 0;
      numPointsInNeighbor = 0;
      for(int i = 0; i < regMaxNeighbors; ++i) distanceSq[i] = 0.0f;
      for(int neigh = 0; neigh < 27; ++neigh){
        neighbor = nodeArray[blockID + regDepthIndex].neighbors[neigh];
        if(neighbor != -1){
          numPointsInNeighbor = nodeArray[neighbor].numPoints;
          regNNPointIndex = nodeArray[neighbor].pointIndex;
          for(int p = 0; p < numPointsInNeighbor; ++p){
            neighborCoord = points[regNNPointIndex + p];
            currentDistanceSq = ((coord.x - neighborCoord.x)*(coord.x - neighborCoord.x)) +
              ((coord.y - neighborCoord.y)*(coord.y - neighborCoord.y)) +
              ((coord.z - neighborCoord.z)*(coord.z - neighborCoord.z));
            if(n < regMaxNeighbors){
              if(currentDistanceSq > largestDistanceSq){
                largestDistanceSq = currentDistanceSq;
                indexOfFurthestNeighbor = n;
              }
              distanceSq[n] = currentDistanceSq;
              neighborIndices[(regPointIndex + threadID)*regMaxNeighbors + n] = regNNPointIndex + p;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (n*3)] = neighborCoord.x;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (n*3 + 1)] = neighborCoord.y;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (n*3 + 2)] = neighborCoord.z;
              ++n;
            }
            else if(n == regMaxNeighbors && currentDistanceSq >= largestDistanceSq) continue;
            else{
              neighborIndices[(regPointIndex + threadID)*regMaxNeighbors + indexOfFurthestNeighbor] = regNNPointIndex + p;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (indexOfFurthestNeighbor*3)] = neighborCoord.x;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (indexOfFurthestNeighbor*3 + 1)] = neighborCoord.y;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (indexOfFurthestNeighbor*3 + 2)] = neighborCoord.z;
              distanceSq[indexOfFurthestNeighbor] = currentDistanceSq;
              largestDistanceSq = 0.0f;
              for(int i = 0; i < regMaxNeighbors; ++i){
                if(distanceSq[i] > largestDistanceSq){
                  largestDistanceSq = distanceSq[i];
                  indexOfFurthestNeighbor = i;
                }
              }
            }
          }
        }
      }
      numNeighbors[regPointIndex + threadID] = n;
      for(int np = 0; np < n; ++np){
        centroid.x += cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3)];
        centroid.y += cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3 + 1)];
        centroid.z += cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3 + 2)];
      }
      centroid = {centroid.x/n, centroid.y/n, centroid.z/n};
      for(int np = 0; np < n; ++np){
        cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3)] -= centroid.x;
        cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3 + 1)] -= centroid.y;
        cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3 + 2)] -= centroid.z;
      }
    }
    delete[] distanceSq;
  }
}
__global__ void findNormalNeighborsAndComputeCMatrix(int numNodesAtDepth, int depthIndex, int maxNeighbors, Node* nodeArray, Sphere* spheres, float* cMatrix, int* neighborIndices, int* numNeighbors){
  int blockID = blockIdx.y * gridDim.x + blockIdx.x;
  if(blockID < numNodesAtDepth){
    float3 centroid = {0.0f,0.0f,0.0f};
    int n = 0;
    int regDepthIndex = depthIndex;
    int numPointsInNode = nodeArray[blockID + regDepthIndex].numPoints;
    int neighbor = -1;
    int regMaxNeighbors = maxNeighbors;
    int regPointIndex = nodeArray[blockID + regDepthIndex].pointIndex;
    float3 coord = {0.0f,0.0f,0.0f};
    float3 neighborCoord = {0.0f,0.0f,0.0f};
    float currentDistanceSq = 0.0f;
    float largestDistanceSq = 0.0f;
    int indexOfFurthestNeighbor = -1;
    int regNNPointIndex = 0;
    int numPointsInNeighbor = 0;
    float* distanceSq = new float[regMaxNeighbors];
    for(int threadID = threadIdx.x; threadID < numPointsInNode; threadID += blockDim.x){
      n = 0;
      coord = spheres[regPointIndex + threadID].center;
      currentDistanceSq = 0.0f;
      largestDistanceSq = 0.0f;
      indexOfFurthestNeighbor = -1;
      regNNPointIndex = 0;
      numPointsInNeighbor = 0;
      for(int i = 0; i < regMaxNeighbors; ++i) distanceSq[i] = 0.0f;
      for(int neigh = 0; neigh < 27; ++neigh){
        neighbor = nodeArray[blockID + regDepthIndex].neighbors[neigh];
        if(neighbor != -1){
          numPointsInNeighbor = nodeArray[neighbor].numPoints;
          regNNPointIndex = nodeArray[neighbor].pointIndex;
          for(int p = 0; p < numPointsInNeighbor; ++p){
            neighborCoord = spheres[regNNPointIndex + p].center;
            currentDistanceSq = ((coord.x - neighborCoord.x)*(coord.x - neighborCoord.x)) +
              ((coord.y - neighborCoord.y)*(coord.y - neighborCoord.y)) +
              ((coord.z - neighborCoord.z)*(coord.z - neighborCoord.z));
            if(n < regMaxNeighbors){
              if(currentDistanceSq > largestDistanceSq){
                largestDistanceSq = currentDistanceSq;
                indexOfFurthestNeighbor = n;
              }
              distanceSq[n] = currentDistanceSq;
              neighborIndices[(regPointIndex + threadID)*regMaxNeighbors + n] = regNNPointIndex + p;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (n*3)] = neighborCoord.x;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (n*3 + 1)] = neighborCoord.y;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (n*3 + 2)] = neighborCoord.z;
              ++n;
            }
            else if(n == regMaxNeighbors && currentDistanceSq >= largestDistanceSq) continue;
            else{
              neighborIndices[(regPointIndex + threadID)*regMaxNeighbors + indexOfFurthestNeighbor] = regNNPointIndex + p;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (indexOfFurthestNeighbor*3)] = neighborCoord.x;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (indexOfFurthestNeighbor*3 + 1)] = neighborCoord.y;
              cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (indexOfFurthestNeighbor*3 + 2)] = neighborCoord.z;
              distanceSq[indexOfFurthestNeighbor] = currentDistanceSq;
              largestDistanceSq = 0.0f;
              for(int i = 0; i < regMaxNeighbors; ++i){
                if(distanceSq[i] > largestDistanceSq){
                  largestDistanceSq = distanceSq[i];
                  indexOfFurthestNeighbor = i;
                }
              }
            }
          }
        }
      }
      numNeighbors[regPointIndex + threadID] = n;
      for(int np = 0; np < n; ++np){
        centroid.x += cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3)];
        centroid.y += cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3 + 1)];
        centroid.z += cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3 + 2)];
      }
      centroid = {centroid.x/n, centroid.y/n, centroid.z/n};
      for(int np = 0; np < n; ++np){
        cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3)] -= centroid.x;
        cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3 + 1)] -= centroid.y;
        cMatrix[(regPointIndex + threadID)*regMaxNeighbors*3 + (np*3 + 2)] -= centroid.z;
      }
    }
    delete[] distanceSq;
  }
}
__global__ void transposeFloatMatrix(int m, int n, float* matrix){
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  if(globalID < m*n){
    int2 regLocation = {globalID/n,globalID%n};
    float regPastValue = matrix[globalID];
    __syncthreads();
    matrix[regLocation.y*m + regLocation.x] = regPastValue;
  }
}
__global__ void setNormal(int currentPoint, float* vt, float3* normals){
  normals[currentPoint] = {vt[2],vt[5],vt[8]};
}
__global__ void checkForAbiguity(int numPoints, int numCameras, float3* normals, float3* points, float3* cameraPositions, bool* ambiguous){
  int blockID = blockIdx.y * gridDim.x + blockIdx.x;
  if(blockID < numPoints && threadIdx.x < numCameras){
    float3 regCameraPosition = cameraPositions[threadIdx.x];
    float3 coord = points[blockID];
    float3 norm = normals[blockID];
    __shared__ int directionCheck;
    directionCheck = 0;
    __syncthreads();
    coord = {regCameraPosition.x - coord.x,regCameraPosition.y - coord.y,regCameraPosition.z - coord.z};
    float dot = (coord.x*norm.x) + (coord.y*norm.y) + (coord.z*norm.z);
    if(dot < 0) atomicSub(&directionCheck,1);
    else atomicAdd(&directionCheck,1);
    __syncthreads();
    if(abs(directionCheck) == numCameras){
      if(directionCheck < 0){
        normals[blockID] = {-1.0f*norm.x,-1.0f*norm.y,-1.0f*norm.z};
      }
      ambiguous[blockID] = false;
    }
    else{
      ambiguous[blockID] = true;
    }
  }
}
__global__ void checkForAbiguity(int numPoints, int numCameras, float3* normals, Sphere* spheres, float3* cameraPositions, bool* ambiguous){
  int blockID = blockIdx.y * gridDim.x + blockIdx.x;
  if(blockID < numPoints && threadIdx.x < numCameras){
    float3 regCameraPosition = cameraPositions[threadIdx.x];
    float3 coord = spheres[blockID].center;
    float3 norm = normals[blockID];
    __shared__ int directionCheck;
    directionCheck = 0;
    __syncthreads();
    coord = {regCameraPosition.x - coord.x,regCameraPosition.y - coord.y,regCameraPosition.z - coord.z};
    float dot = (coord.x*norm.x) + (coord.y*norm.y) + (coord.z*norm.z);
    if(dot < 0) atomicSub(&directionCheck,1);
    else atomicAdd(&directionCheck,1);
    __syncthreads();
    if(abs(directionCheck) == numCameras){
      if(directionCheck < 0){
        normals[blockID] = {-1.0f*norm.x,-1.0f*norm.y,-1.0f*norm.z};
      }
      ambiguous[blockID] = false;
    }
    else{
      ambiguous[blockID] = true;
    }
  }
}
__global__ void reorient(int numNodesAtDepth, int depthIndex, Node* nodeArray, int* numNeighbors, int maxNeighbors, float3* normals, int* neighborIndices, bool* ambiguous){
  int blockID = blockIdx.y * gridDim.x + blockIdx.x;
  if(blockID < numNodesAtDepth){
    __shared__ bool ambiguityExists;
    ambiguityExists = true;
    __syncthreads();
    int regDepthIndex = depthIndex;
    int numPointsInNode = nodeArray[blockID + regDepthIndex].numPoints;
    int regPointIndex = nodeArray[blockID + regDepthIndex].pointIndex;
    int2 directionCounter = {0,0};
    float3 norm = {0.0f,0.0f,0.0f};
    float3 neighNorm = {0.0f,0.0f,0.0f};
    int regNumNeighbors = 0;
    int regNeighborIndex = 0;
    bool amb = true;
    while(ambiguityExists){
      ambiguityExists = false;
      for(int threadID = threadIdx.x; threadID < numPointsInNode; threadID += blockDim.x){
        if(!ambiguous[regPointIndex + threadID]) continue;
        amb = true;
        directionCounter = {0,0};
        norm = normals[regPointIndex + threadID];
        regNumNeighbors = numNeighbors[regPointIndex + threadID];
        for(int np = 0; np < regNumNeighbors; ++np){
          regNeighborIndex = neighborIndices[(regPointIndex + threadID)*maxNeighbors + np];
          if(ambiguous[regNeighborIndex]) continue;
          amb = false;
          neighNorm = normals[regNeighborIndex];
          if((norm.x*neighNorm.x)+(norm.y*neighNorm.y)+(norm.z*neighNorm.z) < 0){
            ++directionCounter.x;
          }
          else{
            ++directionCounter.y;
          }
        }
        if(!amb){
          ambiguous[blockID] = false;
          if(directionCounter.x < directionCounter.y){
            normals[blockID] = {-1.0f*norm.x,-1.0f*norm.y,-1.0f*norm.z};
          }
        }
        else{
          ambiguityExists = true;
        }
      }
      if(ambiguityExists) __syncthreads();
    }
  }
}

//vertex edge and face array kernels
__global__ void findVertexOwners(Node* nodeArray, int numNodes, int depthIndex, int* vertexLUT, int* numVertices, int* ownerInidices, int* vertexPlacement){
  int blockID = blockIdx.y * gridDim.x + blockIdx.x;
  if(blockID < numNodes){
    int vertexID = (blockID*8) + threadIdx.x;
    int sharesVertex = -1;
    for(int i = 0; i < 7; ++i){//iterate through neighbors that share vertex
      sharesVertex = vertexLUT[(threadIdx.x*7) + i];
      if(nodeArray[blockID + depthIndex].neighbors[sharesVertex] != -1 && sharesVertex < 13){//less than itself
        return;
      }
    }
    //if thread reaches this point, that means that this vertex is owned by the current node
    //also means owner == current node
    ownerInidices[vertexID] = blockID + depthIndex;
    vertexPlacement[vertexID] = threadIdx.x;
    atomicAdd(numVertices, 1);
  }
}
__global__ void fillUniqueVertexArray(Node* nodeArray, Vertex* vertexArray, int numVertices, int vertexIndex,int depthIndex, int depth, float width, int* vertexLUT, int* ownerInidices, int* vertexPlacement){
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  if(globalID < numVertices){

    int ownerNodeIndex = ownerInidices[globalID];
    int ownedIndex = vertexPlacement[globalID];

    nodeArray[ownerNodeIndex].vertices[ownedIndex] = globalID + vertexIndex;

    float depthHalfWidth = width/powf(2, depth + 1);
    Vertex vertex = Vertex();
    vertex.coord.x = nodeArray[ownerNodeIndex].center.x + (depthHalfWidth*coordPlacementIdentity[ownedIndex].x);
    vertex.coord.y = nodeArray[ownerNodeIndex].center.y + (depthHalfWidth*coordPlacementIdentity[ownedIndex].y);
    vertex.coord.z = nodeArray[ownerNodeIndex].center.z + (depthHalfWidth*coordPlacementIdentity[ownedIndex].z);
    vertex.color = nodeArray[ownerNodeIndex].color;
    vertex.depth = depth;
    vertex.nodes[0] = ownerNodeIndex;
    int neighborSharingVertex = -1;
    for(int i = 0; i < 7; ++i){
      neighborSharingVertex = nodeArray[ownerNodeIndex].neighbors[vertexLUT[(ownedIndex*7) + i]];
      vertex.nodes[i + 1] =  neighborSharingVertex;
      if(neighborSharingVertex == -1) continue;
      nodeArray[neighborSharingVertex].vertices[6 - i] = globalID + vertexIndex;
    }
    vertexArray[globalID] = vertex;
  }
}
__global__ void findEdgeOwners(Node* nodeArray, int numNodes, int depthIndex, int* edgeLUT, int* numEdges, int* ownerInidices, int* edgePlacement){
  int blockID = blockIdx.y * gridDim.x + blockIdx.x;
  if(blockID < numNodes){
    int edgeID = (blockID*12) + threadIdx.x;
    int sharesEdge = -1;
    for(int i = 0; i < 3; ++i){//iterate through neighbors that share edge
      sharesEdge = edgeLUT[(threadIdx.x*3) + i];
      if(nodeArray[blockID + depthIndex].neighbors[sharesEdge] != -1 && sharesEdge < 13){//less than itself
        return;
      }
    }
    //if thread reaches this point, that means that this edge is owned by the current node
    //also means owner == current node
    ownerInidices[edgeID] = blockID + depthIndex;
    edgePlacement[edgeID] = threadIdx.x;
    atomicAdd(numEdges, 1);
  }
}
__global__ void fillUniqueEdgeArray(Node* nodeArray, Edge* edgeArray, int numEdges, int edgeIndex, int depthIndex, int depth, float width, int* edgeLUT, int* ownerInidices, int* edgePlacement){
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  if(globalID < numEdges){
    int ownerNodeIndex = ownerInidices[globalID];
    int ownedIndex = edgePlacement[globalID];
    nodeArray[ownerNodeIndex].edges[ownedIndex] = globalID + edgeIndex;

    float depthHalfWidth = width/powf(2, depth + 1);
    Edge edge = Edge();
    edge.v1 = nodeArray[ownerNodeIndex].vertices[vertexEdgeIdentity[ownedIndex].x];
    edge.v2 = nodeArray[ownerNodeIndex].vertices[vertexEdgeIdentity[ownedIndex].y];
    edge.color = nodeArray[ownerNodeIndex].color;
    edge.depth = depth;
    edge.nodes[0] = ownerNodeIndex;
    int neighborSharingEdge = -1;
    int placement = 0;
    int neighborPlacement = 0;
    for(int i = 0; i < 3; ++i){
      neighborPlacement = edgeLUT[(ownedIndex*3) + i];
      neighborSharingEdge = nodeArray[ownerNodeIndex].neighbors[neighborPlacement];
      edge.nodes[i + 1] =  neighborSharingEdge;
      if(neighborSharingEdge == -1) continue;
      placement = ownedIndex + 13 - neighborPlacement;
      if(neighborPlacement <= 8 || ((ownedIndex == 4 || ownedIndex == 5) && neighborPlacement < 12)){
        --placement;
      }
      else if(neighborPlacement >= 18 || ((ownedIndex == 6 || ownedIndex == 7) && neighborPlacement > 14)){
        ++placement;
      }
      nodeArray[neighborSharingEdge].edges[placement] = globalID + edgeIndex;
    }
    edgeArray[globalID] = edge;
  }
}
__global__ void findFaceOwners(Node* nodeArray, int numNodes, int depthIndex, int* faceLUT, int* numFaces, int* ownerInidices, int* facePlacement){
  int blockID = blockIdx.y * gridDim.x + blockIdx.x;
  if(blockID < numNodes){
    int faceID = (blockID*6) + threadIdx.x;
    int sharesFace = -1;
    sharesFace = faceLUT[threadIdx.x];
    if(nodeArray[blockID + depthIndex].neighbors[sharesFace] != -1 && sharesFace < 13){//less than itself
      return;
    }
    //if thread reaches this point, that means that this face is owned by the current node
    //also means owner == current node
    ownerInidices[faceID] = blockID + depthIndex;
    facePlacement[faceID] = threadIdx.x;
    atomicAdd(numFaces, 1);
  }

}
__global__ void fillUniqueFaceArray(Node* nodeArray, Face* faceArray, int numFaces, int faceIndex, int depthIndex, int depth, float width, int* faceLUT, int* ownerInidices, int* facePlacement){
  int globalID = blockIdx.x * blockDim.x + threadIdx.x;
  if(globalID < numFaces){

    int ownerNodeIndex = ownerInidices[globalID];
    int ownedIndex = facePlacement[globalID];

    nodeArray[ownerNodeIndex].faces[ownedIndex] = globalID + faceIndex;

    float depthHalfWidth = width/powf(2, depth + 1);
    Face face = Face();

    face.e1 = nodeArray[ownerNodeIndex].edges[edgeFaceIdentity[ownedIndex].x];
    face.e2 = nodeArray[ownerNodeIndex].edges[edgeFaceIdentity[ownedIndex].y];
    face.e3 = nodeArray[ownerNodeIndex].edges[edgeFaceIdentity[ownedIndex].z];
    face.e4 = nodeArray[ownerNodeIndex].edges[edgeFaceIdentity[ownedIndex].w];
    face.color = nodeArray[ownerNodeIndex].color;
    face.depth = depth;
    face.nodes[0] = ownerNodeIndex;
    int neighborSharingFace = -1;
    neighborSharingFace = nodeArray[ownerNodeIndex].neighbors[faceLUT[ownedIndex]];
    face.nodes[1] =  neighborSharingFace;
    if(neighborSharingFace != -1)nodeArray[neighborSharingFace].faces[5 - ownedIndex] = globalID + faceIndex;
    faceArray[globalID] = face;

  }
}

Octree::Octree(){
  this->depth = 1;
  this->spheres = NULL;
  this->normals = NULL;

  this->nodes = NULL;
  this->vertices = NULL;
  this->edges = NULL;
  this->faces = NULL;

  this->pointNodeIndex = NULL;
  this->nodeDepthIndex = NULL;
  this->vertexDepthIndex = NULL;
  this->edgeDepthIndex = NULL;
  this->faceDepthIndex = NULL;
}
Octree::~Octree(){
  if(this->normals != NULL && this->normals->state != null) delete this->normals;
  if(this->nodes != NULL && this->nodes->state != null) delete this->nodes;
  if(this->vertices != NULL && this->vertices->state != null) delete this->vertices;
  if(this->edges != NULL && this->edges->state != null) delete this->edges;
  if(this->faces != NULL && this->faces->state != null) delete this->faces;
  if(this->pointNodeIndex != NULL && this->pointNodeIndex->state != null) delete this->pointNodeIndex;
  if(this->nodeDepthIndex != NULL && this->nodeDepthIndex->state != null) delete this->nodeDepthIndex;
  if(this->vertexDepthIndex != NULL && this->vertexDepthIndex->state != null) delete this->vertexDepthIndex;
  if(this->edgeDepthIndex != NULL && this->edgeDepthIndex->state != null) delete this->edgeDepthIndex;
  if(this->faceDepthIndex != NULL && this->faceDepthIndex->state != null) delete this->faceDepthIndex;
}

Octree::Octree(int numSpheres, Sphere* spheres, int depth, bool createVEF){
  this->min = {FLT_MAX,FLT_MAX,FLT_MAX};
  this->max = {-FLT_MAX,-FLT_MAX,-FLT_MAX};
  this->spheres = NULL;
  this->normals = NULL;
  this->nodes = NULL;
  this->vertices = NULL;
  this->edges = NULL;
  this->faces = NULL;
  this->pointNodeIndex = NULL;
  this->nodeDepthIndex = NULL;
  this->vertexDepthIndex = NULL;
  this->edgeDepthIndex = NULL;
  this->faceDepthIndex = NULL;

  this->depth = depth;
  if(this->depth >= 10){
    std::cout<<"ERROR this octree currently only supports a depth of 10 at the max"<<std::endl;
    exit(-1);
  }

  this->spheres = new Unity<Sphere>(spheres, numSpheres, cpu);

  for(int i = 0; i < numSpheres; ++i){
    if(this->min.x > spheres[i].center.x) this->min.x = spheres[i].center.x;
    else if(this->max.x < spheres[i].center.x) this->max.x = spheres[i].center.x;
    if(this->min.y > spheres[i].center.y) this->min.y = spheres[i].center.y;
    else if(this->max.y < spheres[i].center.y) this->max.y = spheres[i].center.y;
    if(this->min.z > spheres[i].center.z) this->min.z = spheres[i].center.z;
    else if(this->max.z < spheres[i].center.z) this->max.z = spheres[i].center.z;
  }

  this->center.x = (this->max.x + this->min.x)/2;
  this->center.y = (this->max.y + this->min.y)/2;
  this->center.z = (this->max.z + this->min.z)/2;

  this->width = this->max.x - this->min.x;
  if(this->width < this->max.y - this->min.y) this->width = this->max.y - this->min.y;
  if(this->width < this->max.z - this->min.z) this->width = this->max.z - this->min.z;

  this->width = ceil(this->width);
  if(((int)this->width) % 2) this->width++;
  this->width += 6.0f;
  this->max = this->center + (this->width/2);
  this->min = this->center - (this->width/2);

  printf("\nmin = %f,%f,%f\n",this->min.x,this->min.y,this->min.z);
  printf("max = %f,%f,%f\n",this->max.x,this->max.y,this->max.z);
  printf("bounding box width = %f\n", this->width);
  printf("center = %f,%f,%f\n",this->center.x,this->center.y,this->center.z);
  printf("number of points = %lu\n\n", this->spheres->numElements);

  this->createFinestNodes();
  this->fillInCoarserDepths();
  this->fillNeighborhoods();
  if(!createVEF) this->createVEFArrays();
}
Octree::Octree(int numSpheres, Sphere* spheres, float deepestWidth, bool createVEF){
  this->min = {FLT_MAX,FLT_MAX,FLT_MAX};
  this->max = {-FLT_MAX,-FLT_MAX,-FLT_MAX};
  this->spheres = NULL;
  this->normals = NULL;
  this->nodes = NULL;
  this->vertices = NULL;
  this->edges = NULL;
  this->faces = NULL;
  this->pointNodeIndex = NULL;
  this->nodeDepthIndex = NULL;
  this->vertexDepthIndex = NULL;
  this->edgeDepthIndex = NULL;
  this->faceDepthIndex = NULL;

  this->spheres = new Unity<Sphere>(spheres, numSpheres, cpu);

  for(int i = 0; i < numSpheres; ++i){
    if(this->min.x > spheres[i].center.x) this->min.x = spheres[i].center.x;
    else if(this->max.x < spheres[i].center.x) this->max.x = spheres[i].center.x;
    if(this->min.y > spheres[i].center.y) this->min.y = spheres[i].center.y;
    else if(this->max.y < spheres[i].center.y) this->max.y = spheres[i].center.y;
    if(this->min.z > spheres[i].center.z) this->min.z = spheres[i].center.z;
    else if(this->max.z < spheres[i].center.z) this->max.z = spheres[i].center.z;
  }

  this->center.x = (this->max.x + this->min.x)/2;
  this->center.y = (this->max.y + this->min.y)/2;
  this->center.z = (this->max.z + this->min.z)/2;

  this->width = this->max.x - this->min.x;
  if(this->width < this->max.y - this->min.y) this->width = this->max.y - this->min.y;
  if(this->width < this->max.z - this->min.z) this->width = this->max.z - this->min.z;

  this->width = ceil(this->width);
  if(((int)this->width) % 2) this->width++;
  this->width += 6.0f;
  this->max = this->center + (this->width/2);
  this->min = this->center - (this->width/2);

  printf("\nmin = %f,%f,%f\n",this->min.x,this->min.y,this->min.z);
  printf("max = %f,%f,%f\n",this->max.x,this->max.y,this->max.z);
  printf("bounding box width = %f\n", this->width);
  printf("center = %f,%f,%f\n",this->center.x,this->center.y,this->center.z);
  printf("number of points = %lu\n\n", this->spheres->numElements);

  this->depth = 0;
  float finestWidth = this->width;
  while(finestWidth > deepestWidth){
    finestWidth /= 2.0f;
    ++this->depth;
  }
  if(this->depth >= 10){
    std::cout<<"ERROR this octree currently only supports a depth of 10 at the max"<<std::endl;
    exit(-1);
  }

  this->createFinestNodes();
  this->fillInCoarserDepths();
  this->fillNeighborhoods();
  if(createVEF) this->createVEFArrays();
}

Octree::Octree(Unity<Sphere>* spheres, int depth, bool createVEF){
  this->min = {FLT_MAX,FLT_MAX,FLT_MAX};
  this->max = {-FLT_MAX,-FLT_MAX,-FLT_MAX};
  this->normals = NULL;
  this->nodes = NULL;
  this->vertices = NULL;
  this->edges = NULL;
  this->faces = NULL;
  this->pointNodeIndex = NULL;
  this->nodeDepthIndex = NULL;
  this->vertexDepthIndex = NULL;
  this->edgeDepthIndex = NULL;
  this->faceDepthIndex = NULL;

  this->spheres = spheres;
  if(this->spheres->state == gpu) this->spheres->transferMemoryTo(cpu);
  Sphere* spheres_host = this->spheres->host;

  for(int i = 0; i < spheres->numElements; ++i){
    if(this->min.x > spheres_host[i].center.x) this->min.x = spheres_host[i].center.x;
    else if(this->max.x < spheres_host[i].center.x) this->max.x = spheres_host[i].center.x;
    if(this->min.y > spheres_host[i].center.y) this->min.y = spheres_host[i].center.y;
    else if(this->max.y < spheres_host[i].center.y) this->max.y = spheres_host[i].center.y;
    if(this->min.z > spheres_host[i].center.z) this->min.z = spheres_host[i].center.z;
    else if(this->max.z < spheres_host[i].center.z) this->max.z = spheres_host[i].center.z;
  }


  this->max = {this->max.x,this->max.y,this->max.z};

  this->center.x = (this->max.x + this->min.x)/2;
  this->center.y = (this->max.y + this->min.y)/2;
  this->center.z = (this->max.z + this->min.z)/2;

  this->width = this->max.x - this->min.x;
  if(this->width < this->max.y - this->min.y) this->width = this->max.y - this->min.y;
  if(this->width < this->max.z - this->min.z) this->width = this->max.z - this->min.z;

  this->width = ceil(this->width);
  if(((int)this->width) % 2) this->width++;
  this->width += 6.0f;
  this->max = this->center + (this->width/2);
  this->min = this->center - (this->width/2);

  printf("\nmin = %f,%f,%f\n",this->min.x,this->min.y,this->min.z);
  printf("max = %f,%f,%f\n",this->max.x,this->max.y,this->max.z);
  printf("bounding box width = %f\n", this->width);
  printf("center = %f,%f,%f\n",this->center.x,this->center.y,this->center.z);
  printf("number of points = %lu\n\n", this->spheres->numElements);

  this->depth = depth;
  if(this->depth >= 10){
    std::cout<<"ERROR this octree currently only supports a depth of 10 at the max"<<std::endl;
    exit(-1);
  }

  this->createFinestNodes();
  this->fillInCoarserDepths();
  this->fillNeighborhoods();
  if(createVEF) this->createVEFArrays();
}
Octree::Octree(Unity<Sphere>* spheres, float deepestWidth, bool createVEF){
  this->min = {FLT_MAX,FLT_MAX,FLT_MAX};
  this->max = {-FLT_MAX,-FLT_MAX,-FLT_MAX};
  this->normals = NULL;
  this->nodes = NULL;
  this->vertices = NULL;
  this->edges = NULL;
  this->faces = NULL;
  this->pointNodeIndex = NULL;
  this->nodeDepthIndex = NULL;
  this->vertexDepthIndex = NULL;
  this->edgeDepthIndex = NULL;
  this->faceDepthIndex = NULL;

  this->spheres = spheres;
  if(this->spheres->state == gpu) this->spheres->transferMemoryTo(cpu);
  Sphere* spheres_host = this->spheres->host;

  for(int i = 0; i < spheres->numElements; ++i){
    if(this->min.x > spheres_host[i].center.x) this->min.x = spheres_host[i].center.x;
    else if(this->max.x < spheres_host[i].center.x) this->max.x = spheres_host[i].center.x;
    if(this->min.y > spheres_host[i].center.y) this->min.y = spheres_host[i].center.y;
    else if(this->max.y < spheres_host[i].center.y) this->max.y = spheres_host[i].center.y;
    if(this->min.z > spheres_host[i].center.z) this->min.z = spheres_host[i].center.z;
    else if(this->max.z < spheres_host[i].center.z) this->max.z = spheres_host[i].center.z;
  }

  this->max = {this->max.x,this->max.y,this->max.z};

  this->center.x = (this->max.x + this->min.x)/2;
  this->center.y = (this->max.y + this->min.y)/2;
  this->center.z = (this->max.z + this->min.z)/2;

  this->width = this->max.x - this->min.x;
  if(this->width < this->max.y - this->min.y) this->width = this->max.y - this->min.y;
  if(this->width < this->max.z - this->min.z) this->width = this->max.z - this->min.z;

  this->width = ceil(this->width);
  if(((int)this->width) % 2) this->width++;
  this->width += 6.0f;
  this->max = this->center + (this->width/2);
  this->min = this->center - (this->width/2);

  printf("\nmin = %f,%f,%f\n",this->min.x,this->min.y,this->min.z);
  printf("max = %f,%f,%f\n",this->max.x,this->max.y,this->max.z);
  printf("bounding box width = %f\n", this->width);
  printf("center = %f,%f,%f\n",this->center.x,this->center.y,this->center.z);
  printf("number of points = %lu\n\n", this->spheres->numElements);

  this->depth = 0;
  float finestWidth = this->width;
  while(finestWidth > deepestWidth){
    finestWidth /= 2.0f;
    ++this->depth;
  }
  if(this->depth >= 10){
    std::cout<<"ERROR this octree currently only supports a depth of 10 at the max"<<std::endl;
    exit(-1);
  }

  this->createFinestNodes();
  this->fillInCoarserDepths();
  this->fillNeighborhoods();
  if(createVEF) this->createVEFArrays();
}

//TODO check if using iterator for nodePoint works
void Octree::createFinestNodes(){
  this->spheres->transferMemoryTo(both);
  int* finestNodeKeys = new int[this->spheres->numElements]();
  float3* finestNodeCenters = new float3[this->spheres->numElements]();

  int* finestNodeKeys_device;
  float3* finestNodeCenters_device;
  CudaSafeCall(cudaMalloc((void**)&finestNodeKeys_device, this->spheres->numElements*sizeof(int)));
  CudaSafeCall(cudaMalloc((void**)&finestNodeCenters_device, this->spheres->numElements*sizeof(float3)));

  dim3 grid = {1,1,1};
  dim3 block = {1,1,1};
  if(this->spheres->numElements < 65535) grid.x = (unsigned int) this->spheres->numElements;
  else{
    grid.x = 65535;
    while(grid.x*block.x < this->spheres->numElements){
      ++block.x;
    }
    while(grid.x*block.x > this->spheres->numElements){
      --grid.x;
      if(grid.x*block.x < this->spheres->numElements){
        ++grid.x;//to ensure that numThreads > this->spheres->numElements
        break;
      }
    }
  }


  getNodeKeys<<<grid,block>>>(this->spheres->device, finestNodeCenters_device, finestNodeKeys_device, this->center, this->width, this->spheres->numElements, this->depth);
  CudaCheckError();

  thrust::device_ptr<int> kys(finestNodeKeys_device);
  thrust::device_ptr<float3> cnts(finestNodeCenters_device);

  thrust::device_vector<float3> sortedCnts(this->spheres->numElements);

  thrust::counting_iterator<unsigned int> iter(0);
  thrust::device_vector<unsigned int> indices(this->spheres->numElements);
  thrust::copy(iter, iter + this->spheres->numElements, indices.begin());

  unsigned int* nodePointIndex = new unsigned int[this->spheres->numElements]();
  CudaSafeCall(cudaMemcpy(nodePointIndex, thrust::raw_pointer_cast(indices.data()), this->spheres->numElements*sizeof(unsigned int),cudaMemcpyDeviceToHost));

  thrust::sort_by_key(kys, kys + this->spheres->numElements, indices.begin());
  CudaSafeCall(cudaMemcpy(finestNodeKeys, finestNodeKeys_device, this->spheres->numElements*sizeof(int),cudaMemcpyDeviceToHost));
  CudaSafeCall(cudaFree(finestNodeKeys_device));


  thrust::device_ptr<Sphere> sphs(this->spheres->device);
  thrust::device_vector<Sphere> sortedSphs(this->spheres->numElements);
  thrust::gather(indices.begin(), indices.end(), sphs, sortedSphs.begin());
  CudaSafeCall(cudaMemcpy(this->spheres->host, thrust::raw_pointer_cast(sortedSphs.data()), this->spheres->numElements*sizeof(Sphere),cudaMemcpyDeviceToHost));

  this->spheres->clear(gpu);

  thrust::gather(indices.begin(), indices.end(), cnts, sortedCnts.begin());

  CudaSafeCall(cudaMemcpy(finestNodeCenters, thrust::raw_pointer_cast(sortedCnts.data()), this->spheres->numElements*sizeof(float3),cudaMemcpyDeviceToHost));
  CudaSafeCall(cudaFree(finestNodeCenters_device));

  if(this->normals != NULL && this->normals->state != null && this->normals->numElements != 0){
    this->normals->transferMemoryTo(both);
    thrust::device_ptr<float3> nmls(this->normals->device);
    thrust::device_vector<float3> sortedNmls(this->spheres->numElements);
    thrust::gather(indices.begin(), indices.end(), nmls, sortedNmls.begin());
    CudaSafeCall(cudaMemcpy(this->normals->host, thrust::raw_pointer_cast(sortedNmls.data()), this->spheres->numElements*sizeof(float3),cudaMemcpyDeviceToHost));
    this->normals->clear(gpu);
  }

  thrust::pair<int*, unsigned int*> new_end;//the last value of these node arrays

  new_end = thrust::unique_by_key(finestNodeKeys, finestNodeKeys + this->spheres->numElements, nodePointIndex);

  bool foundFirst = false;
  int numUniqueNodes = 0;
  while(numUniqueNodes != this->spheres->numElements){
    if(finestNodeKeys[numUniqueNodes] == *new_end.first){
      if(foundFirst) break;
      else foundFirst = true;
    }
    numUniqueNodes++;
  }

  Node* finestNodes = new Node[numUniqueNodes]();
  for(int i = 0; i < numUniqueNodes; ++i){

    Node currentNode;
    currentNode.key = finestNodeKeys[i];

    currentNode.center = finestNodeCenters[nodePointIndex[i]];

    currentNode.pointIndex = nodePointIndex[i];
    currentNode.depth = this->depth;
    if(i + 1 != numUniqueNodes){
      currentNode.numPoints = nodePointIndex[i + 1] - nodePointIndex[i];
    }
    else{
      currentNode.numPoints = this->spheres->numElements - nodePointIndex[i];

    }

    finestNodes[i] = currentNode;
  }
  this->nodes = new Unity<Node>(finestNodes, numUniqueNodes, cpu);

  delete[] finestNodeCenters;
  delete[] finestNodeKeys;
  delete[] nodePointIndex;
}
void Octree::fillInCoarserDepths(){
  if(this->nodes == NULL || this->nodes->state == null){
    std::cout<<"ERROR cannot create coarse depths before finest nodes have been built"<<std::endl;
    exit(-1);
  }

  Node* uniqueNodes_device;
  if(this->nodes->state < 2){
    this->nodes->transferMemoryTo(gpu);
  }
  int numUniqueNodes = this->nodes->numElements;
  CudaSafeCall(cudaMalloc((void**)&uniqueNodes_device, this->nodes->numElements*sizeof(Node)));
  CudaSafeCall(cudaMemcpy(uniqueNodes_device, this->nodes->device, this->nodes->numElements*sizeof(Node), cudaMemcpyDeviceToDevice));
  delete this->nodes;
  this->nodes = NULL;
  unsigned int totalNodes = 0;

  Node** nodeArray2D = new Node*[this->depth + 1];

  int* nodeAddresses_device;
  int* nodeNumbers_device;

  unsigned int* nodeDepthIndex_host = new unsigned int[this->depth + 1]();
  unsigned int* pointNodeIndex_device;
  CudaSafeCall(cudaMalloc((void**)&pointNodeIndex_device, this->spheres->numElements*sizeof(unsigned int)));

  for(int d = this->depth; d >= 0; --d){
    dim3 grid = {1,1,1};
    dim3 block = {1,1,1};
    if(numUniqueNodes < 65535) grid.x = (unsigned int) numUniqueNodes;
    else{
      grid.x = 65535;
      while(grid.x*block.x < numUniqueNodes){
        ++block.x;
      }
      while(grid.x*block.x > numUniqueNodes){
        --grid.x;
        if(grid.x*block.x < numUniqueNodes){
          ++grid.x;//to ensure that numThreads > numUniqueNodes
          break;
        }
      }
    }

    CudaSafeCall(cudaMalloc((void**)&nodeNumbers_device, numUniqueNodes * sizeof(int)));
    CudaSafeCall(cudaMalloc((void**)&nodeAddresses_device, numUniqueNodes * sizeof(int)));
    //this is just to fill the arrays with 0s
    calculateNodeAddresses(grid, block, numUniqueNodes, uniqueNodes_device, nodeAddresses_device, nodeNumbers_device);

    int numNodesAtDepth = 0;
    CudaSafeCall(cudaMemcpy(&numNodesAtDepth, nodeAddresses_device + (numUniqueNodes - 1), sizeof(int), cudaMemcpyDeviceToHost));

    numNodesAtDepth = (d > 0) ? numNodesAtDepth + 8: 1;


    CudaSafeCall(cudaMalloc((void**)&nodeArray2D[this->depth - d], numNodesAtDepth*sizeof(Node)));

    fillBlankNodeArray<<<grid,block>>>(uniqueNodes_device, nodeNumbers_device,  nodeAddresses_device, nodeArray2D[this->depth - d], numUniqueNodes, d, this->width);
    CudaCheckError();
    cudaDeviceSynchronize();
    if(this->depth == d){
      fillFinestNodeArrayWithUniques<<<grid,block>>>(uniqueNodes_device, nodeAddresses_device,nodeArray2D[this->depth - d], numUniqueNodes, pointNodeIndex_device);
      CudaCheckError();
    }
    else{
      fillNodeArrayWithUniques<<<grid,block>>>(uniqueNodes_device, nodeAddresses_device, nodeArray2D[this->depth - d], nodeArray2D[this->depth - d - 1], numUniqueNodes);
      CudaCheckError();
    }
    CudaSafeCall(cudaFree(uniqueNodes_device));
    CudaSafeCall(cudaFree(nodeAddresses_device));
    CudaSafeCall(cudaFree(nodeNumbers_device));

    numUniqueNodes = numNodesAtDepth / 8;

    //get unique nodes at next depth
    if(d > 0){
      CudaSafeCall(cudaMalloc((void**)&uniqueNodes_device, numUniqueNodes*sizeof(Node)));
      if(numUniqueNodes < 65535) grid.x = (unsigned int) numUniqueNodes;
      else{
        grid.x = 65535;
        while(grid.x*block.x < numUniqueNodes){
          ++block.x;
        }
        while(grid.x*block.x > numUniqueNodes){
          --grid.x;
          if(grid.x*block.x < numUniqueNodes){
            ++grid.x;//to ensure that numThreads > numUniqueNodes
            break;
          }
        }
      }
      generateParentalUniqueNodes<<<grid,block>>>(uniqueNodes_device, nodeArray2D[this->depth - d], numNodesAtDepth, this->width);
      CudaCheckError();
    }
    nodeDepthIndex_host[this->depth - d] = totalNodes;
    totalNodes += numNodesAtDepth;
  }

  Node* nodeArray_device;
  CudaSafeCall(cudaMalloc((void**)&nodeArray_device, totalNodes*sizeof(Node)));
  for(int i = 0; i <= this->depth; ++i){
    if(i < this->depth){
      CudaSafeCall(cudaMemcpy(nodeArray_device + nodeDepthIndex_host[i], nodeArray2D[i], (nodeDepthIndex_host[i+1]-nodeDepthIndex_host[i])*sizeof(Node), cudaMemcpyDeviceToDevice));
    }
    else{
      CudaSafeCall(cudaMemcpy(nodeArray_device + nodeDepthIndex_host[i], nodeArray2D[i], sizeof(Node), cudaMemcpyDeviceToDevice));
    }
    CudaSafeCall(cudaFree(nodeArray2D[i]));
  }
  delete[] nodeArray2D;
  printf("TOTAL NODES = %d\n\n",totalNodes);
  this->pointNodeIndex = new Unity<unsigned int>(pointNodeIndex_device, this->spheres->numElements, gpu);
  this->nodes = new Unity<Node>(nodeArray_device, totalNodes, gpu);
  this->nodeDepthIndex = new Unity<unsigned int>(nodeDepthIndex_host, this->depth + 1, cpu);
}

void Octree::fillNeighborhoods(){
  if(this->nodes == NULL || this->nodes->state == null){
    std::cout<<"ERROR cannot fill neighborhood without nodes"<<std::endl;
    exit(-1);
  }
  int* parentLUT = new int[216];
  int* childLUT = new int[216];

  int c[6][6][6];
  int p[6][6][6];

  int numbParent = 0;
  for (int k = 5; k >= 0; k -= 2){
    for (int i = 0; i < 6; i += 2){
    	for (int j = 5; j >= 0; j -= 2){
    		int numb = 0;
    		for (int l = 0; l < 2; l++){
    		  for (int m = 0; m < 2; m++){
    				for (int n = 0; n < 2; n++){
    					c[i+m][j-n][k-l] = numb++;
    					p[i+m][j-n][k-l] = numbParent;
    				}
    			}
        }
        numbParent++;
      }
    }
  }

  int numbLUT = 0;
  for (int k = 3; k > 1; k--){
    for (int i = 2; i < 4; i++){
    	for (int j = 3; j > 1; j--){
    		int numb = 0;
    		for (int n = 1; n >= -1; n--){
    			for (int l = -1; l <= 1; l++){
    				for (int m = 1; m >= -1; m--){
    					parentLUT[numbLUT*27 + numb] = p[i+l][j+m][k+n];
    					childLUT[numbLUT*27 + numb] = c[i+l][j+m][k+n];
              numb++;
    				}
    			}
        }
        numbLUT++;
      }
    }
  }

  int* parentLUT_device;
  int* childLUT_device;
  CudaSafeCall(cudaMalloc((void**)&parentLUT_device, 216*sizeof(int)));
  CudaSafeCall(cudaMalloc((void**)&childLUT_device, 216*sizeof(int)));
  CudaSafeCall(cudaMemcpy(parentLUT_device, parentLUT, 216*sizeof(int), cudaMemcpyHostToDevice));
  CudaSafeCall(cudaMemcpy(childLUT_device, childLUT, 216*sizeof(int), cudaMemcpyHostToDevice));
  delete[] parentLUT;
  delete[] childLUT;

  dim3 grid = {1,1,1};
  dim3 block = {27,1,1};
  int numNodesAtDepth;
  int depthStartingIndex;
  int childDepthIndex;

  if(this->nodeDepthIndex->state != both || this->nodeDepthIndex->state != cpu){
    this->nodeDepthIndex->transferMemoryTo(cpu);
  }
  unsigned int* nodeDepthIndex_host = (unsigned int*) this->nodeDepthIndex->host;
  if(this->nodes->state != both || this->nodes->state != gpu){
    this->nodes->transferMemoryTo(gpu);
  }
  for(int i = this->depth; i >= 0 ; --i){
    numNodesAtDepth = 1;
    depthStartingIndex = nodeDepthIndex_host[i];
    childDepthIndex = -1;
    if(i != this->depth){
      numNodesAtDepth = nodeDepthIndex_host[i + 1] - depthStartingIndex;
    }
    if(i != 0){
      childDepthIndex = nodeDepthIndex_host[i - 1];
    }
    if(numNodesAtDepth < 65535) grid.x = (unsigned int) numNodesAtDepth;
    else{
      grid.x = 65535;
      while(grid.x*grid.y < numNodesAtDepth){
        ++grid.y;
      }
      while(grid.x*grid.y > numNodesAtDepth){
        --grid.x;
        if(grid.x*grid.y < numNodesAtDepth){
          ++grid.x;//to ensure that numThreads > totalNodes
          break;
        }
      }
    }
    computeNeighboringNodes<<<grid, block>>>(this->nodes->device, numNodesAtDepth, depthStartingIndex, parentLUT_device, childLUT_device, childDepthIndex);
    cudaDeviceSynchronize();
    CudaCheckError();
  }

  CudaSafeCall(cudaFree(childLUT_device));
  CudaSafeCall(cudaFree(parentLUT_device));
  if(this->nodes->state == both) this->nodes->transferMemoryTo(cpu);
};
void Octree::computeVertexArray(){
  clock_t cudatimer;
  cudatimer = clock();

  int vertexLUT[8][7]{
    {0,1,3,4,9,10,12},
    {1,2,4,5,10,11,14},
    {3,4,6,7,12,15,16},
    {4,5,7,8,14,16,17},
    {9,10,12,18,19,21,22},
    {10,11,14,19,20,22,23},
    {12,15,16,21,22,24,25},
    {14,16,17,22,23,25,26}
  };
  int* vertexLUT_device;
  CudaSafeCall(cudaMalloc((void**)&vertexLUT_device, 56*sizeof(int)));
  for(int i = 0; i < 8; ++i){
    CudaSafeCall(cudaMemcpy(vertexLUT_device + i*7, &(vertexLUT[i]), 7*sizeof(int), cudaMemcpyHostToDevice));
  }

  int numNodesAtDepth = 0;
  dim3 grid = {1,1,1};
  dim3 block = {1,1,1};
  int* atomicCounter;
  int numVertices = 0;
  CudaSafeCall(cudaMalloc((void**)&atomicCounter, sizeof(int)));
  CudaSafeCall(cudaMemcpy(atomicCounter, &numVertices, sizeof(int), cudaMemcpyHostToDevice));
  Vertex** vertexArray2D_device;
  CudaSafeCall(cudaMalloc((void**)&vertexArray2D_device, (this->depth + 1)*sizeof(Vertex*)));
  Vertex** vertexArray2D = new Vertex*[this->depth + 1];

  if(this->nodeDepthIndex->state != both || this->nodeDepthIndex->state != cpu){
    this->nodeDepthIndex->transferMemoryTo(cpu);
  }
  unsigned int* nodeDepthIndex_host = (unsigned int*) this->nodeDepthIndex->host;
  if(this->nodes->state != both || this->nodes->state != gpu){
    this->nodes->transferMemoryTo(gpu);
  }

  unsigned int* vertexDepthIndex_host = new unsigned int[this->depth + 1];

  int prevCount = 0;
  int* ownerInidices_device;
  int* vertexPlacement_device;
  int* compactedOwnerArray_device;
  int* compactedVertexPlacement_device;
  for(int i = 0; i <= this->depth; ++i){
    //reset previously allocated resources
    grid.y = 1;
    block.x = 8;
    if(i == this->depth){
      numNodesAtDepth = 1;
    }
    else{
      numNodesAtDepth = nodeDepthIndex_host[i + 1] - nodeDepthIndex_host[i];
    }
    if(numNodesAtDepth < 65535) grid.x = (unsigned int) numNodesAtDepth;
    else{
      grid.x = 65535;
      while(grid.x*grid.y < numNodesAtDepth){
        ++grid.y;
      }
      while(grid.x*grid.y > numNodesAtDepth){
        --grid.x;
      }
      if(grid.x*grid.y < numNodesAtDepth){
        ++grid.x;
      }
    }
    int* ownerInidices = new int[numNodesAtDepth*8];
    for(int v = 0;v < numNodesAtDepth*8; ++v){
      ownerInidices[v] = -1;
    }
    CudaSafeCall(cudaMalloc((void**)&ownerInidices_device,numNodesAtDepth*8*sizeof(int)));
    CudaSafeCall(cudaMalloc((void**)&vertexPlacement_device,numNodesAtDepth*8*sizeof(int)));
    CudaSafeCall(cudaMemcpy(ownerInidices_device, ownerInidices, numNodesAtDepth*8*sizeof(int), cudaMemcpyHostToDevice));
    CudaSafeCall(cudaMemcpy(vertexPlacement_device, ownerInidices, numNodesAtDepth*8*sizeof(int), cudaMemcpyHostToDevice));
    delete[] ownerInidices;

    prevCount = numVertices;
    vertexDepthIndex_host[i] = numVertices;

    findVertexOwners<<<grid, block>>>(this->nodes->device, numNodesAtDepth,
      nodeDepthIndex_host[i], vertexLUT_device, atomicCounter, ownerInidices_device, vertexPlacement_device);
    CudaCheckError();
    CudaSafeCall(cudaMemcpy(&numVertices, atomicCounter, sizeof(int), cudaMemcpyDeviceToHost));
    if(i == this->depth  && numVertices - prevCount != 8){
      std::cout<<"ERROR GENERATING VERTICES, vertices at depth 0 != 8 -> "<<numVertices - prevCount<<std::endl;
      exit(-1);
    }

    CudaSafeCall(cudaMalloc((void**)&vertexArray2D[i], (numVertices - prevCount)*sizeof(Vertex)));
    CudaSafeCall(cudaMalloc((void**)&compactedOwnerArray_device,(numVertices - prevCount)*sizeof(int)));
    CudaSafeCall(cudaMalloc((void**)&compactedVertexPlacement_device,(numVertices - prevCount)*sizeof(int)));

    thrust::device_ptr<int> arrayToCompact(ownerInidices_device);
    thrust::device_ptr<int> arrayOut(compactedOwnerArray_device);
    thrust::device_ptr<int> placementToCompact(vertexPlacement_device);
    thrust::device_ptr<int> placementOut(compactedVertexPlacement_device);

    thrust::copy_if(arrayToCompact, arrayToCompact + (numNodesAtDepth*8), arrayOut, is_not_neg());
    CudaCheckError();
    thrust::copy_if(placementToCompact, placementToCompact + (numNodesAtDepth*8), placementOut, is_not_neg());
    CudaCheckError();

    CudaSafeCall(cudaFree(ownerInidices_device));
    CudaSafeCall(cudaFree(vertexPlacement_device));

    //reset and allocated resources
    grid.y = 1;
    block.x = 1;
    if(numVertices - prevCount < 65535) grid.x = (unsigned int) numVertices - prevCount;
    else{
      grid.x = 65535;
      while(grid.x*block.x < numVertices - prevCount){
        ++block.x;
      }
      while(grid.x*block.x > numVertices - prevCount){
        --grid.x;
        if(grid.x*block.x < numVertices - prevCount){
          ++grid.x;
          break;
        }
      }
    }

    fillUniqueVertexArray<<<grid, block>>>(this->nodes->device, vertexArray2D[i],
      numVertices - prevCount, vertexDepthIndex_host[i], nodeDepthIndex_host[i], this->depth - i,
      this->width, vertexLUT_device, compactedOwnerArray_device, compactedVertexPlacement_device);
    CudaCheckError();
    CudaSafeCall(cudaFree(compactedOwnerArray_device));
    CudaSafeCall(cudaFree(compactedVertexPlacement_device));

  }
  Vertex* vertices_device;
  CudaSafeCall(cudaMalloc((void**)&vertices_device, numVertices*sizeof(Vertex)));
  for(int i = 0; i <= this->depth; ++i){
    if(i < this->depth){
      CudaSafeCall(cudaMemcpy(vertices_device + vertexDepthIndex_host[i], vertexArray2D[i], (vertexDepthIndex_host[i+1] - vertexDepthIndex_host[i])*sizeof(Vertex), cudaMemcpyDeviceToDevice));
    }
    else{
      CudaSafeCall(cudaMemcpy(vertices_device + vertexDepthIndex_host[i], vertexArray2D[i], 8*sizeof(Vertex), cudaMemcpyDeviceToDevice));
    }
    CudaSafeCall(cudaFree(vertexArray2D[i]));
  }
  CudaSafeCall(cudaFree(vertexLUT_device));
  CudaSafeCall(cudaFree(vertexArray2D_device));

  this->vertices = new Unity<Vertex>(vertices_device, numVertices, gpu);
  this->vertexDepthIndex = new Unity<unsigned int>(vertexDepthIndex_host, this->depth + 1, cpu);

  printf("octree createVertexArray took %f seconds.\n", ((float) clock() - cudatimer)/CLOCKS_PER_SEC);
}
void Octree::computeEdgeArray(){
  clock_t cudatimer;
  cudatimer = clock();

  int edgeLUT[12][3]{
    {1,4,10},
    {3,4,12},
    {4,5,14},
    {4,7,16},
    {9,10,12},
    {10,11,14},
    {12,15,16},
    {14,16,17},
    {10,19,22},
    {12,21,22},
    {14,22,23},
    {16,22,25}
  };

  int* edgeLUT_device;
  CudaSafeCall(cudaMalloc((void**)&edgeLUT_device, 36*sizeof(int)));
  for(int i = 0; i < 12; ++i){
    CudaSafeCall(cudaMemcpy(edgeLUT_device + i*3, &(edgeLUT[i]), 3*sizeof(int), cudaMemcpyHostToDevice));
  }

  int numNodesAtDepth = 0;
  dim3 grid = {1,1,1};
  dim3 block = {1,1,1};
  int* atomicCounter;
  int numEdges = 0;
  CudaSafeCall(cudaMalloc((void**)&atomicCounter, sizeof(int)));
  CudaSafeCall(cudaMemcpy(atomicCounter, &numEdges, sizeof(int), cudaMemcpyHostToDevice));
  Edge** edgeArray2D_device;
  CudaSafeCall(cudaMalloc((void**)&edgeArray2D_device, (this->depth + 1)*sizeof(Edge*)));
  Edge** edgeArray2D = new Edge*[this->depth + 1];

  if(this->nodeDepthIndex->state != both || this->nodeDepthIndex->state != cpu){
    this->nodeDepthIndex->transferMemoryTo(cpu);
  }
  unsigned int* nodeDepthIndex_host = (unsigned int*) this->nodeDepthIndex->host;
  if(this->nodes->state != both || this->nodes->state != gpu){
    this->nodes->transferMemoryTo(gpu);
  }

  unsigned int* edgeDepthIndex_host = new unsigned int[this->depth + 1];

  int prevCount = 0;
  int* ownerInidices_device;
  int* edgePlacement_device;
  int* compactedOwnerArray_device;
  int* compactedEdgePlacement_device;
  for(int i = 0; i <= this->depth; ++i){
    //reset previously allocated resources
    grid.y = 1;
    block.x = 12;
    if(i == this->depth){
      numNodesAtDepth = 1;
    }
    else{
      numNodesAtDepth = nodeDepthIndex_host[i + 1] - nodeDepthIndex_host[i];
    }
    if(numNodesAtDepth < 65535) grid.x = (unsigned int) numNodesAtDepth;
    else{
      grid.x = 65535;
      while(grid.x*grid.y < numNodesAtDepth){
        ++grid.y;
      }
      while(grid.x*grid.y > numNodesAtDepth){
        --grid.x;

      }
      if(grid.x*grid.y < numNodesAtDepth){
        ++grid.x;
      }
    }
    int* ownerInidices = new int[numNodesAtDepth*12];
    for(int v = 0;v < numNodesAtDepth*12; ++v){
      ownerInidices[v] = -1;
    }
    CudaSafeCall(cudaMalloc((void**)&ownerInidices_device,numNodesAtDepth*12*sizeof(int)));
    CudaSafeCall(cudaMalloc((void**)&edgePlacement_device,numNodesAtDepth*12*sizeof(int)));
    CudaSafeCall(cudaMemcpy(ownerInidices_device, ownerInidices, numNodesAtDepth*12*sizeof(int), cudaMemcpyHostToDevice));
    CudaSafeCall(cudaMemcpy(edgePlacement_device, ownerInidices, numNodesAtDepth*12*sizeof(int), cudaMemcpyHostToDevice));
    delete[] ownerInidices;

    prevCount = numEdges;
    edgeDepthIndex_host[i] = numEdges;
    findEdgeOwners<<<grid, block>>>(this->nodes->device, numNodesAtDepth,
      nodeDepthIndex_host[i], edgeLUT_device, atomicCounter, ownerInidices_device, edgePlacement_device);
    CudaCheckError();
    CudaSafeCall(cudaMemcpy(&numEdges, atomicCounter, sizeof(int), cudaMemcpyDeviceToHost));
    if(i == this->depth  && numEdges - prevCount != 12){
      std::cout<<"ERROR GENERATING EDGES, edges at depth 0 != 12 -> "<<numEdges - prevCount<<std::endl;
      exit(-1);
    }

    CudaSafeCall(cudaMalloc((void**)&edgeArray2D[i], (numEdges - prevCount)*sizeof(Edge)));
    CudaSafeCall(cudaMalloc((void**)&compactedOwnerArray_device,(numEdges - prevCount)*sizeof(int)));
    CudaSafeCall(cudaMalloc((void**)&compactedEdgePlacement_device,(numEdges - prevCount)*sizeof(int)));

    thrust::device_ptr<int> arrayToCompact(ownerInidices_device);
    thrust::device_ptr<int> arrayOut(compactedOwnerArray_device);
    thrust::device_ptr<int> placementToCompact(edgePlacement_device);
    thrust::device_ptr<int> placementOut(compactedEdgePlacement_device);

    thrust::copy_if(arrayToCompact, arrayToCompact + (numNodesAtDepth*12), arrayOut, is_not_neg());
    CudaCheckError();
    thrust::copy_if(placementToCompact, placementToCompact + (numNodesAtDepth*12), placementOut, is_not_neg());
    CudaCheckError();

    CudaSafeCall(cudaFree(ownerInidices_device));
    CudaSafeCall(cudaFree(edgePlacement_device));

    //reset and allocated resources
    grid.y = 1;
    block.x = 1;
    if(numEdges - prevCount < 65535) grid.x = (unsigned int) numEdges - prevCount;
    else{
      grid.x = 65535;
      while(grid.x*block.x < numEdges - prevCount){
        ++block.x;
      }
      while(grid.x*block.x > numEdges - prevCount){
        --grid.x;
        if(grid.x*block.x < numEdges - prevCount){
          ++grid.x;
          break;
        }
      }
    }

    fillUniqueEdgeArray<<<grid, block>>>(this->nodes->device, edgeArray2D[i],
      numEdges - prevCount, edgeDepthIndex_host[i], nodeDepthIndex_host[i], this->depth - i,
      this->width, edgeLUT_device, compactedOwnerArray_device, compactedEdgePlacement_device);
    CudaCheckError();
    CudaSafeCall(cudaFree(compactedOwnerArray_device));
    CudaSafeCall(cudaFree(compactedEdgePlacement_device));

  }
  Edge* edgeArray_device;
  CudaSafeCall(cudaMalloc((void**)&edgeArray_device, numEdges*sizeof(Edge)));
  for(int i = 0; i <= this->depth; ++i){
    if(i < this->depth){
      CudaSafeCall(cudaMemcpy(edgeArray_device + edgeDepthIndex_host[i], edgeArray2D[i], (edgeDepthIndex_host[i+1] - edgeDepthIndex_host[i])*sizeof(Edge), cudaMemcpyDeviceToDevice));
    }
    else{
      CudaSafeCall(cudaMemcpy(edgeArray_device + edgeDepthIndex_host[i], edgeArray2D[i], 12*sizeof(Edge), cudaMemcpyDeviceToDevice));
    }
    CudaSafeCall(cudaFree(edgeArray2D[i]));
  }
  CudaSafeCall(cudaFree(edgeLUT_device));
  CudaSafeCall(cudaFree(edgeArray2D_device));
  this->edges = new Unity<Edge>(edgeArray_device, numEdges, gpu);
  this->edgeDepthIndex = new Unity<unsigned int>(edgeDepthIndex_host, this->depth + 1, cpu);

  printf("octree createEdgeArray took %f seconds.\n", ((float) clock() - cudatimer)/CLOCKS_PER_SEC);
}
void Octree::computeFaceArray(){
  clock_t cudatimer;
  cudatimer = clock();

  int faceLUT[6] = {4,10,12,14,16,22};
  int* faceLUT_device;
  CudaSafeCall(cudaMalloc((void**)&faceLUT_device, 6*sizeof(int)));
  CudaSafeCall(cudaMemcpy(faceLUT_device, &faceLUT, 6*sizeof(int), cudaMemcpyHostToDevice));

  int numNodesAtDepth = 0;
  dim3 grid = {1,1,1};
  dim3 block = {1,1,1};
  int* atomicCounter;
  int numFaces = 0;
  CudaSafeCall(cudaMalloc((void**)&atomicCounter, sizeof(int)));
  CudaSafeCall(cudaMemcpy(atomicCounter, &numFaces, sizeof(int), cudaMemcpyHostToDevice));
  Face** faceArray2D_device;
  CudaSafeCall(cudaMalloc((void**)&faceArray2D_device, (this->depth + 1)*sizeof(Face*)));
  Face** faceArray2D = new Face*[this->depth + 1];

  if(this->nodeDepthIndex->state != both || this->nodeDepthIndex->state != cpu){
    this->nodeDepthIndex->transferMemoryTo(cpu);
  }
  unsigned int* nodeDepthIndex_host = (unsigned int*) this->nodeDepthIndex->host;
  if(this->nodes->state != both || this->nodes->state != gpu){
    this->nodes->transferMemoryTo(gpu);
  }

  unsigned int* faceDepthIndex_host = new unsigned int[this->depth + 1];

  int prevCount = 0;
  int* ownerInidices_device;
  int* facePlacement_device;
  int* compactedOwnerArray_device;
  int* compactedFacePlacement_device;
  for(int i = 0; i <= this->depth; ++i){
    //reset previously allocated resources
    grid.y = 1;
    block.x = 6;
    if(i == this->depth){
      numNodesAtDepth = 1;
    }
    else{
      numNodesAtDepth = nodeDepthIndex_host[i + 1] - nodeDepthIndex_host[i];
    }
    if(numNodesAtDepth < 65535) grid.x = (unsigned int) numNodesAtDepth;
    else{
      grid.x = 65535;
      while(grid.x*grid.y < numNodesAtDepth){
        ++grid.y;
      }
      while(grid.x*grid.y > numNodesAtDepth){
        --grid.x;

      }
      if(grid.x*grid.y < numNodesAtDepth){
        ++grid.x;
      }
    }
    int* ownerInidices = new int[numNodesAtDepth*6];
    for(int v = 0;v < numNodesAtDepth*6; ++v){
      ownerInidices[v] = -1;
    }
    CudaSafeCall(cudaMalloc((void**)&ownerInidices_device,numNodesAtDepth*6*sizeof(int)));
    CudaSafeCall(cudaMalloc((void**)&facePlacement_device,numNodesAtDepth*6*sizeof(int)));
    CudaSafeCall(cudaMemcpy(ownerInidices_device, ownerInidices, numNodesAtDepth*6*sizeof(int), cudaMemcpyHostToDevice));
    CudaSafeCall(cudaMemcpy(facePlacement_device, ownerInidices, numNodesAtDepth*6*sizeof(int), cudaMemcpyHostToDevice));
    delete[] ownerInidices;

    prevCount = numFaces;
    faceDepthIndex_host[i] = numFaces;
    findFaceOwners<<<grid, block>>>((Node*) this->nodes->device, numNodesAtDepth,
      nodeDepthIndex_host[i], faceLUT_device, atomicCounter, ownerInidices_device, facePlacement_device);
    CudaCheckError();
    CudaSafeCall(cudaMemcpy(&numFaces, atomicCounter, sizeof(int), cudaMemcpyDeviceToHost));
    if(i == this->depth  && numFaces - prevCount != 6){
      std::cout<<"ERROR GENERATING FACES, faces at depth 0 != 6 -> "<<numFaces - prevCount<<std::endl;
      exit(-1);
    }

    CudaSafeCall(cudaMalloc((void**)&faceArray2D[i], (numFaces - prevCount)*sizeof(Face)));
    CudaSafeCall(cudaMalloc((void**)&compactedOwnerArray_device,(numFaces - prevCount)*sizeof(int)));
    CudaSafeCall(cudaMalloc((void**)&compactedFacePlacement_device,(numFaces - prevCount)*sizeof(int)));

    thrust::device_ptr<int> arrayToCompact(ownerInidices_device);
    thrust::device_ptr<int> arrayOut(compactedOwnerArray_device);
    thrust::device_ptr<int> placementToCompact(facePlacement_device);
    thrust::device_ptr<int> placementOut(compactedFacePlacement_device);

    thrust::copy_if(arrayToCompact, arrayToCompact + (numNodesAtDepth*6), arrayOut, is_not_neg());
    CudaCheckError();
    thrust::copy_if(placementToCompact, placementToCompact + (numNodesAtDepth*6), placementOut, is_not_neg());
    CudaCheckError();

    CudaSafeCall(cudaFree(ownerInidices_device));
    CudaSafeCall(cudaFree(facePlacement_device));

    //reset and allocated resources
    grid.y = 1;
    block.x = 1;
    if(numFaces - prevCount < 65535) grid.x = (unsigned int) numFaces - prevCount;
    else{
      grid.x = 65535;
      while(grid.x*block.x < numFaces - prevCount){
        ++block.x;
      }
      while(grid.x*block.x > numFaces - prevCount){
        --grid.x;
        if(grid.x*block.x < numFaces - prevCount){
          ++grid.x;
          break;
        }
      }
    }

    fillUniqueFaceArray<<<grid, block>>>((Node*) this->nodes->device, faceArray2D[i],
      numFaces - prevCount, numFaces, nodeDepthIndex_host[i], this->depth - i,
      this->width, faceLUT_device, compactedOwnerArray_device, compactedFacePlacement_device);
    CudaCheckError();
    CudaSafeCall(cudaFree(compactedOwnerArray_device));
    CudaSafeCall(cudaFree(compactedFacePlacement_device));

  }
  Face* faceArray_device;
  CudaSafeCall(cudaMalloc((void**)&faceArray_device, numFaces*sizeof(Face)));
  for(int i = 0; i <= this->depth; ++i){
    if(i < this->depth){
      CudaSafeCall(cudaMemcpy(faceArray_device + faceDepthIndex_host[i], faceArray2D[i], (faceDepthIndex_host[i+1] - faceDepthIndex_host[i])*sizeof(Face), cudaMemcpyDeviceToDevice));
    }
    else{
      CudaSafeCall(cudaMemcpy(faceArray_device + faceDepthIndex_host[i], faceArray2D[i], 6*sizeof(Face), cudaMemcpyDeviceToDevice));
    }
    CudaSafeCall(cudaFree(faceArray2D[i]));
  }
  CudaSafeCall(cudaFree(faceLUT_device));
  CudaSafeCall(cudaFree(faceArray2D_device));
  this->faces = new Unity<Face>(faceArray_device, numFaces, gpu);
  this->faceDepthIndex = new Unity<unsigned int>(faceDepthIndex_host, this->depth + 1, cpu);

  printf("octree createFaceArray took %f seconds.\n", ((float) clock() - cudatimer)/CLOCKS_PER_SEC);
}

// RUN THIS
void Octree::createVEFArrays(){
  this->computeVertexArray();
  this->computeEdgeArray();
  this->computeFaceArray();
}

void Octree::computeNormals(int minNeighForNorms, int maxNeighbors){
  std::cout<<"\n";
  clock_t cudatimer;
  cudatimer = clock();

  int numNodesAtDepth = 0;
  int currentNumNeighbors = 0;
  int currentNeighborIndex = -1;
  int maxPointsInOneNode = 0;
  int minPossibleNeighbors = std::numeric_limits<int>::max();
  int nodeDepthIndex = 0;
  int currentDepth = 0;
  MemoryState node_origin = this->nodes->state;
  MemoryState nodeDepthIndex_origin = this->nodeDepthIndex->state;

  if(node_origin != both || node_origin != cpu){
    this->nodes->transferMemoryTo(cpu);
  }
  Node* nodes_host = (Node*) this->nodes->host;
  if(nodeDepthIndex_origin != both || nodeDepthIndex_origin != cpu){
    this->nodes->transferMemoryTo(cpu);
  }
  unsigned int* nodeDepthIndex_host = (unsigned int*) this->nodeDepthIndex->host;

  for(int i = 0; i < this->nodes->numElements; ++i){
    currentNumNeighbors = 0;
    if(minPossibleNeighbors < minNeighForNorms){
      ++currentDepth;
      i = nodeDepthIndex_host[currentDepth];
      minPossibleNeighbors = std::numeric_limits<int>::max();
      maxPointsInOneNode = 0;
    }
    if(this->depth - nodes_host[i].depth != currentDepth){
      if(minPossibleNeighbors >= minNeighForNorms) break;
      ++currentDepth;
    }
    if(maxPointsInOneNode < nodes_host[i].numPoints){
      maxPointsInOneNode = nodes_host[i].numPoints;
    }
    for(int n = 0; n < 27; ++n){
      currentNeighborIndex = nodes_host[i].neighbors[n];
      if(currentNeighborIndex != -1) currentNumNeighbors += nodes_host[currentNeighborIndex].numPoints;
    }
    if(minPossibleNeighbors > currentNumNeighbors){
      minPossibleNeighbors = currentNumNeighbors;
    }
  }

  nodeDepthIndex = nodeDepthIndex_host[currentDepth];
  numNodesAtDepth = nodeDepthIndex_host[currentDepth + 1] - nodeDepthIndex;
  std::cout<<"Continuing with depth "<<this->depth - currentDepth<<" nodes starting at "<<nodeDepthIndex<<" with "<<numNodesAtDepth<<" nodes"<<std::endl;
  std::cout<<"Continuing with "<<minPossibleNeighbors<<" minPossibleNeighbors"<<std::endl;
  std::cout<<"Continuing with "<<maxNeighbors<<" maxNeighborsAllowed"<<std::endl;
  std::cout<<"Continuing with "<<maxPointsInOneNode<<" maxPointsInOneNode"<<std::endl;

  uint size = this->spheres->numElements*maxNeighbors*3;
  float* cMatrix_device;
  int* neighborIndices_device;
  int* numRealNeighbors_device;
  int* numRealNeighbors = new int[this->spheres->numElements];

  for(int i = 0; i < this->spheres->numElements; ++i){
    numRealNeighbors[i] = 0;
  }
  int* temp = new int[size/3];
  for(int i = 0; i < size/3; ++i){
    temp[i] = -1;
  }

  CudaSafeCall(cudaMalloc((void**)&numRealNeighbors_device, this->spheres->numElements*sizeof(int)));
  CudaSafeCall(cudaMalloc((void**)&cMatrix_device, size*sizeof(float)));
  CudaSafeCall(cudaMalloc((void**)&neighborIndices_device, (size/3)*sizeof(int)));
  CudaSafeCall(cudaMemcpy(numRealNeighbors_device, numRealNeighbors, this->spheres->numElements*sizeof(int), cudaMemcpyHostToDevice));
  CudaSafeCall(cudaMemcpy(neighborIndices_device, temp, (size/3)*sizeof(int), cudaMemcpyHostToDevice));
  delete[] temp;

  dim3 grid = {1,1,1};
  dim3 block = {1,1,1};

  block.x = (maxPointsInOneNode > 1024) ? 1024 : maxPointsInOneNode;
  if(numNodesAtDepth < 65535) grid.x = (unsigned int) numNodesAtDepth;
  else{
    grid.x = 65535;
    while(grid.x*grid.y < numNodesAtDepth){
      ++grid.y;
    }
    while(grid.x*grid.y > numNodesAtDepth){
      --grid.x;
    }
    if(grid.x*grid.y < numNodesAtDepth){
      ++grid.x;
    }
  }
  MemoryState spheres_origin = this->spheres->state;
  if(this->spheres->state != both && this->spheres->state != gpu){
    this->spheres->transferMemoryTo(gpu);
  }
  std::cout<<"WARNING: Sphere normal calculation is currently performed only on sphere centers"<<std::endl;
  findNormalNeighborsAndComputeCMatrix<<<grid, block>>>(numNodesAtDepth, nodeDepthIndex, maxNeighbors,
    this->nodes->device, this->spheres->device, cMatrix_device, neighborIndices_device, numRealNeighbors_device);


  CudaCheckError();
  CudaSafeCall(cudaMemcpy(numRealNeighbors, numRealNeighbors_device, this->spheres->numElements*sizeof(int), cudaMemcpyDeviceToHost));

  float3* normals_device;
  CudaSafeCall(cudaMalloc((void**)&normals_device, this->spheres->numElements*sizeof(float3)));

  cusolverDnHandle_t cusolverH = NULL;
  cublasHandle_t cublasH = NULL;
  cublasStatus_t cublas_status = CUBLAS_STATUS_SUCCESS;
  cusolverStatus_t cusolver_status = CUSOLVER_STATUS_SUCCESS;

  float *d_A, *d_S, *d_U, *d_VT, *d_work, *d_rwork;
  int* devInfo;

  cusolver_status = cusolverDnCreate(&cusolverH);
  assert(CUSOLVER_STATUS_SUCCESS == cublas_status);

  cublas_status = cublasCreate(&cublasH);
  assert(CUBLAS_STATUS_SUCCESS == cublas_status);

  int n = 3;
  int m = 0;
  int lwork = 0;

  //TODO changed this to gesvdjBatched (this will enable doing multiple svds at once)
  for(int p = 0; p < this->spheres->numElements; ++p){
    m = numRealNeighbors[p];
    lwork = 0;
    if(m < minNeighForNorms){
      std::cout<<"ERROR...point does not have enough neighbors...increase min neighbors"<<std::endl;
      exit(-1);
    }
    CudaSafeCall(cudaMalloc((void**)&d_A, m*n*sizeof(float)));
    CudaSafeCall(cudaMalloc((void**)&d_S, n*sizeof(float)));
    CudaSafeCall(cudaMalloc((void**)&d_U, m*m*sizeof(float)));
    CudaSafeCall(cudaMalloc((void**)&d_VT, n*n*sizeof(float)));
    CudaSafeCall(cudaMalloc((void**)&devInfo, sizeof(int)));
    CudaSafeCall(cudaMemcpy(d_A, cMatrix_device + (p*maxNeighbors*n), m*n*sizeof(float), cudaMemcpyDeviceToDevice));
    transposeFloatMatrix<<<m*n,1>>>(m,n,d_A);
    cudaDeviceSynchronize();
    CudaCheckError();

    //query working space of SVD
    cusolver_status = cusolverDnSgesvd_bufferSize(cusolverH, m, n, &lwork);

    assert(cusolver_status == CUSOLVER_STATUS_SUCCESS);

    CudaSafeCall(cudaMalloc((void**)&d_work, lwork*sizeof(float)));
    //SVD

    cusolver_status = cusolverDnSgesvd(cusolverH, 'A', 'A', m, n,
      d_A, m, d_S, d_U, m, d_VT, n, d_work, lwork, d_rwork, devInfo);
    cudaDeviceSynchronize();
    assert(cusolver_status == CUSOLVER_STATUS_SUCCESS);

    //FIND 2 ROWS OF S WITH HEIGHEST VALUES
    //TAKE THOSE ROWS IN VT AND GET CROSS PRODUCT = NORMALS ESTIMATE
    //TODO maybe find better way to cache this and not use only one block
    setNormal<<<1, 1>>>(p, d_VT, normals_device);
    CudaCheckError();

    CudaSafeCall(cudaFree(d_A));
    CudaSafeCall(cudaFree(d_S));
    CudaSafeCall(cudaFree(d_U));
    CudaSafeCall(cudaFree(d_VT));
    CudaSafeCall(cudaFree(d_work));
    CudaSafeCall(cudaFree(devInfo));
  }
  std::cout<<"normals have been estimated by use of svd"<<std::endl;
  if (cublasH) cublasDestroy(cublasH);
  if (cusolverH) cusolverDnDestroy(cusolverH);

  delete[] numRealNeighbors;
  CudaSafeCall(cudaFree(cMatrix_device));

  if(this->normals != NULL) delete this->normals;
  this->normals = new Unity<float3>(normals_device, this->spheres->numElements, gpu);
  this->normals->transferMemoryTo(spheres_origin);
  this->spheres->transferMemoryTo(spheres_origin);
  this->nodes->transferMemoryTo(node_origin);
  this->nodeDepthIndex->transferMemoryTo(nodeDepthIndex_origin);

  CudaSafeCall(cudaFree(numRealNeighbors_device));
  CudaSafeCall(cudaFree(neighborIndices_device));

  printf("octree computeNormals took %f seconds.\n\n", ((float) clock() - cudatimer)/CLOCKS_PER_SEC);
}

void Octree::computeNormals(int minNeighForNorms, int maxNeighbors, unsigned int numCameras, float3* cameraPositions){
  std::cout<<"\n";
  clock_t cudatimer;
  cudatimer = clock();

  int numNodesAtDepth = 0;
  int currentNumNeighbors = 0;
  int currentNeighborIndex = -1;
  int maxPointsInOneNode = 0;
  int minPossibleNeighbors = std::numeric_limits<int>::max();
  int nodeDepthIndex = 0;
  int currentDepth = 0;
  MemoryState node_origin = this->nodes->state;
  MemoryState nodeDepthIndex_origin = this->nodeDepthIndex->state;

  if(node_origin != both || node_origin != cpu){
    this->nodes->transferMemoryTo(cpu);
  }
  Node* nodes_host = (Node*) this->nodes->host;
  if(nodeDepthIndex_origin != both || nodeDepthIndex_origin != cpu){
    this->nodes->transferMemoryTo(cpu);
  }
  unsigned int* nodeDepthIndex_host = (unsigned int*) this->nodeDepthIndex->host;

  for(int i = 0; i < this->nodes->numElements; ++i){
    currentNumNeighbors = 0;
    if(minPossibleNeighbors < minNeighForNorms){
      ++currentDepth;
      i = nodeDepthIndex_host[currentDepth];
      minPossibleNeighbors = std::numeric_limits<int>::max();
      maxPointsInOneNode = 0;
    }
    if(this->depth - nodes_host[i].depth != currentDepth){
      if(minPossibleNeighbors >= minNeighForNorms) break;
      ++currentDepth;
    }
    if(maxPointsInOneNode < nodes_host[i].numPoints){
      maxPointsInOneNode = nodes_host[i].numPoints;
    }
    for(int n = 0; n < 27; ++n){
      currentNeighborIndex = nodes_host[i].neighbors[n];
      if(currentNeighborIndex != -1) currentNumNeighbors += nodes_host[currentNeighborIndex].numPoints;
    }
    if(minPossibleNeighbors > currentNumNeighbors){
      minPossibleNeighbors = currentNumNeighbors;
    }
  }

  nodeDepthIndex = nodeDepthIndex_host[currentDepth];
  numNodesAtDepth = nodeDepthIndex_host[currentDepth + 1] - nodeDepthIndex;
  std::cout<<"Continuing with depth "<<this->depth - currentDepth<<" nodes starting at "<<nodeDepthIndex<<" with "<<numNodesAtDepth<<" nodes"<<std::endl;
  std::cout<<"Continuing with "<<minPossibleNeighbors<<" minPossibleNeighbors"<<std::endl;
  std::cout<<"Continuing with "<<maxNeighbors<<" maxNeighborsAllowed"<<std::endl;
  std::cout<<"Continuing with "<<maxPointsInOneNode<<" maxPovoidintsInOneNode"<<std::endl;

  if(numCameras > 1024){
    std::cout<<"ERROR numCameras > 1024"<<std::endl;
    exit(-1);
  }

  uint size = this->spheres->numElements*maxNeighbors*3;
  float* cMatrix_device;
  int* neighborIndices_device;
  int* numRealNeighbors_device;
  int* numRealNeighbors = new int[this->spheres->numElements];

  for(int i = 0; i < this->spheres->numElements; ++i){
    numRealNeighbors[i] = 0;
  }
  int* temp = new int[size/3];
  for(int i = 0; i < size/3; ++i){
    temp[i] = -1;
  }

  CudaSafeCall(cudaMalloc((void**)&numRealNeighbors_device, this->spheres->numElements*sizeof(int)));
  CudaSafeCall(cudaMalloc((void**)&cMatrix_device, size*sizeof(float)));
  CudaSafeCall(cudaMalloc((void**)&neighborIndices_device, (size/3)*sizeof(int)));
  CudaSafeCall(cudaMemcpy(numRealNeighbors_device, numRealNeighbors, this->spheres->numElements*sizeof(int), cudaMemcpyHostToDevice));
  CudaSafeCall(cudaMemcpy(neighborIndices_device, temp, (size/3)*sizeof(int), cudaMemcpyHostToDevice));
  delete[] temp;

  dim3 grid = {1,1,1};
  dim3 block = {1,1,1};

  block.x = (maxPointsInOneNode > 1024) ? 1024 : maxPointsInOneNode;
  if(numNodesAtDepth < 65535) grid.x = (unsigned int) numNodesAtDepth;
  else{
    grid.x = 65535;
    while(grid.x*grid.y < numNodesAtDepth){
      ++grid.y;
    }
    while(grid.x*grid.y > numNodesAtDepth){
      --grid.x;
    }
    if(grid.x*grid.y < numNodesAtDepth){
      ++grid.x;
    }
  }
  MemoryState spheres_origin = this->spheres->state;
  if(this->spheres->state != both && this->spheres->state != gpu){
    this->spheres->transferMemoryTo(gpu);
  }

  std::cout<<"WARNING: Sphere normal calculation is currently performed only on sphere centers"<<std::endl;
  findNormalNeighborsAndComputeCMatrix<<<grid, block>>>(numNodesAtDepth, nodeDepthIndex, maxNeighbors,
    this->nodes->device, this->spheres->device, cMatrix_device, neighborIndices_device, numRealNeighbors_device);

  CudaCheckError();
  CudaSafeCall(cudaMemcpy(numRealNeighbors, numRealNeighbors_device, this->spheres->numElements*sizeof(int), cudaMemcpyDeviceToHost));

  float3* normals_device;
  CudaSafeCall(cudaMalloc((void**)&normals_device, this->spheres->numElements*sizeof(float3)));

  cusolverDnHandle_t cusolverH = NULL;
  cublasHandle_t cublasH = NULL;
  cublasStatus_t cublas_status = CUBLAS_STATUS_SUCCESS;
  cusolverStatus_t cusolver_status = CUSOLVER_STATUS_SUCCESS;

  float *d_A, *d_S, *d_U, *d_VT, *d_work, *d_rwork;
  int* devInfo;

  cusolver_status = cusolverDnCreate(&cusolverH);
  assert(CUSOLVER_STATUS_SUCCESS == cublas_status);

  cublas_status = cublasCreate(&cublasH);
  assert(CUBLAS_STATUS_SUCCESS == cublas_status);

  int n = 3;
  int m = 0;
  int lwork = 0;

  //TODO changed this to gesvdjBatched (this will enable doing multiple svds at once)
  for(int p = 0; p < this->spheres->numElements; ++p){
    m = numRealNeighbors[p];
    lwork = 0;
    if(m < minNeighForNorms){
      std::cout<<"ERROR...point does not have enough neighbors...increase min neighbors"<<std::endl;
      exit(-1);
    }
    CudaSafeCall(cudaMalloc((void**)&d_A, m*n*sizeof(float)));
    CudaSafeCall(cudaMalloc((void**)&d_S, n*sizeof(float)));
    CudaSafeCall(cudaMalloc((void**)&d_U, m*m*sizeof(float)));
    CudaSafeCall(cudaMalloc((void**)&d_VT, n*n*sizeof(float)));
    CudaSafeCall(cudaMalloc((void**)&devInfo, sizeof(int)));
    CudaSafeCall(cudaMemcpy(d_A, cMatrix_device + (p*maxNeighbors*n), m*n*sizeof(float), cudaMemcpyDeviceToDevice));
    transposeFloatMatrix<<<m*n,1>>>(m,n,d_A);
    cudaDeviceSynchronize();
    CudaCheckError();

    //query working space of SVD
    cusolver_status = cusolverDnSgesvd_bufferSize(cusolverH, m, n, &lwork);

    assert(cusolver_status == CUSOLVER_STATUS_SUCCESS);

    CudaSafeCall(cudaMalloc((void**)&d_work, lwork*sizeof(float)));
    //SVD

    cusolver_status = cusolverDnSgesvd(cusolverH, 'A', 'A', m, n,
      d_A, m, d_S, d_U, m, d_VT, n, d_work, lwork, d_rwork, devInfo);
    cudaDeviceSynchronize();
    assert(cusolver_status == CUSOLVER_STATUS_SUCCESS);

    //FIND 2 ROWS OF S WITH HEIGHEST VALUES
    //TAKE THOSE ROWS IN VT AND GET CROSS PRODUCT = NORMALS ESTIMATE
    //TODO maybe find better way to cache this and not use only one block
    setNormal<<<1, 1>>>(p, d_VT, this->normals->device);
    CudaCheckError();

    CudaSafeCall(cudaFree(d_A));
    CudaSafeCall(cudaFree(d_S));
    CudaSafeCall(cudaFree(d_U));
    CudaSafeCall(cudaFree(d_VT));
    CudaSafeCall(cudaFree(d_work));
    CudaSafeCall(cudaFree(devInfo));
  }
  std::cout<<"normals have been estimated by use of svd"<<std::endl;
  if (cublasH) cublasDestroy(cublasH);
  if (cusolverH) cusolverDnDestroy(cusolverH);

  delete[] numRealNeighbors;
  CudaSafeCall(cudaFree(cMatrix_device));

  if(this->normals != NULL) delete this->normals;
  this->normals = new Unity<float3>(normals_device, this->spheres->numElements, gpu);
  this->normals->transferMemoryTo(spheres_origin);
  this->spheres->transferMemoryTo(spheres_origin);
  this->nodes->transferMemoryTo(node_origin);
  this->nodeDepthIndex->transferMemoryTo(nodeDepthIndex_origin);

  CudaSafeCall(cudaFree(numRealNeighbors_device));
  CudaSafeCall(cudaFree(neighborIndices_device));
\
  printf("octree computeNormals took %f seconds.\n\n", ((float) clock() - cudatimer)/CLOCKS_PER_SEC);
}

void Octree::writeVertexPLY(){
  MemoryState origin;
  if(this->vertices != NULL || this->vertices->state != null && this->vertices->numElements != 0){
    origin = this->vertices->state;
    this->vertices->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print vertices without vertices"<<std::endl;
    exit(-1);
  }
  if(this->pathToFile.length() == 0 && this->name.length() == 0){
    this->name = std::to_string(this->depth);
  }
  else if(this->name.length() == 0) this->name = this->pathToFile.substr(this->pathToFile.find_last_of("/") + 1,this->pathToFile.length() - 4);
  std::string newFile = "data/" + this->name + "_vertices_" + std::to_string(this->depth)+ ".ply";
  std::ofstream plystream(newFile);
  if (plystream.is_open()) {
    std::ostringstream stringBuffer = std::ostringstream("");
    stringBuffer << "ply\nformat ascii 1.0\ncomment object: SSRL test\n";
    stringBuffer << "element vertex ";
    stringBuffer <<  this->vertices->numElements;
    stringBuffer << "\nproperty float x\nproperty float y\nproperty float z\n";
    stringBuffer << "property uchar red\nproperty uchar green\nproperty uchar blue\n";
    stringBuffer << "end_header\n";
    plystream << stringBuffer.str();
    for(int i = 0; i < this->vertices->numElements; ++i){
      stringBuffer = std::ostringstream("");
      stringBuffer << this->vertices->host[i].coord.x;
      stringBuffer << " ";
      stringBuffer << this->vertices->host[i].coord.y;
      stringBuffer << " ";
      stringBuffer << this->vertices->host[i].coord.z;
      stringBuffer << " ";
      stringBuffer << (int) this->vertices->host[i].color.x;
      stringBuffer << " ";
      stringBuffer << (int) this->vertices->host[i].color.y;
      stringBuffer << " ";
      stringBuffer << (int) this->vertices->host[i].color.z;
      stringBuffer << "\n";
      plystream << stringBuffer.str();
    }
    std::cout<<newFile + " has been created.\n"<<std::endl;
  }
  else{
    std::cout << "Unable to open: " + newFile<< std::endl;
    exit(1);
  }
  this->vertices->transferMemoryTo(origin);
  if(origin == gpu) this->vertices->clear(cpu);
}
void Octree::writeEdgePLY(){
  MemoryState origin[2];
  if(this->vertices != NULL || this->vertices->state != null && this->vertices->numElements != 0){
    origin[0] = this->vertices->state;
    this->vertices->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print vertices without vertices"<<std::endl;
    exit(-1);
  }
  if(this->edges != NULL || this->edges->state != null && this->edges->numElements != 0){
    origin[1] = this->edges->state;
    this->edges->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print edges without edges"<<std::endl;
    exit(-1);
  }
  if(this->pathToFile.length() == 0 && this->name.length() == 0){
    this->name = std::to_string(this->depth);
  }
  else if(this->name.length() == 0) this->name = this->pathToFile.substr(this->pathToFile.find_last_of("/") + 1,this->pathToFile.length() - 4);
  std::string newFile = "data/" + this->name + "_edges_" + std::to_string(this->depth)+ ".ply";
  std::ofstream plystream(newFile);
  if (plystream.is_open()) {
    std::ostringstream stringBuffer = std::ostringstream("");
    stringBuffer << "ply\nformat ascii 1.0\ncomment object: SSRL test\n";
    stringBuffer << "element vertex ";
    stringBuffer <<  this->vertices->numElements;
    stringBuffer << "\nproperty float x\nproperty float y\nproperty float z\n";
    stringBuffer << "property uchar red\nproperty uchar green\nproperty uchar blue\n";
    stringBuffer << "element edge ";
    stringBuffer <<  this->edges->numElements;
    stringBuffer << "\nproperty int vertex1\nproperty int vertex2\n";
    stringBuffer << "property uchar red\nproperty uchar green\nproperty uchar blue\n";
    stringBuffer << "end_header\n";
    plystream << stringBuffer.str();
    for(int i = 0; i < this->vertices->numElements; ++i){
      stringBuffer = std::ostringstream("");
      stringBuffer << this->vertices->host[i].coord.x;
      stringBuffer << " ";
      stringBuffer << this->vertices->host[i].coord.y;
      stringBuffer << " ";
      stringBuffer << this->vertices->host[i].coord.z;
      stringBuffer << " ";
      stringBuffer << (int) this->vertices->host[i].color.x;
      stringBuffer << " ";
      stringBuffer << (int) this->vertices->host[i].color.y;
      stringBuffer << " ";
      stringBuffer << (int) this->vertices->host[i].color.z;
      stringBuffer << "\n";
      plystream << stringBuffer.str();
    }
    for(int i = 0; i < this->edges->numElements; ++i){
      stringBuffer = std::ostringstream("");
      stringBuffer << this->edges->host[i].v1;
      stringBuffer << " ";
      stringBuffer << this->edges->host[i].v2;
      stringBuffer << " ";
      stringBuffer << (int) this->edges->host[i].color.x;
      stringBuffer << " ";
      stringBuffer << (int) this->edges->host[i].color.y;
      stringBuffer << " ";
      stringBuffer << (int) this->edges->host[i].color.z;
      stringBuffer << "\n";
      plystream << stringBuffer.str();
    }
    std::cout<<newFile + " has been created.\n"<<std::endl;
  }
  else{
    std::cout << "Unable to open: " + newFile<< std::endl;
    exit(1);
  }
  this->vertices->transferMemoryTo(origin[0]);
  if(origin[0] == gpu) this->vertices->clear(cpu);
  this->edges->transferMemoryTo(origin[1]);
  if(origin[1] == gpu) this->edges->clear(cpu);
}
void Octree::writeCenterPLY(){
  MemoryState origin;
  if(this->nodes != NULL && this->nodes->state != null && this->nodes->numElements != 0){
    origin = this->nodes->state;
    this->nodes->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print nodes without nodes"<<std::endl;
    exit(-1);
  }
  if(this->pathToFile.length() == 0 && this->name.length() == 0){
    this->name = std::to_string(this->depth);
  }
  else if(this->name.length() == 0) this->name = this->pathToFile.substr(this->pathToFile.find_last_of("/") + 1,this->pathToFile.length() - 4);
  std::string newFile = "data/" + this->name + "_centers_" + std::to_string(this->depth)+ ".ply";
  std::ofstream plystream(newFile);
  if (plystream.is_open()) {
    std::ostringstream stringBuffer = std::ostringstream("");
    stringBuffer << "ply\nformat ascii 1.0\ncomment object: SSRL test\n";
    stringBuffer << "element vertex ";
    stringBuffer <<  this->nodes->numElements;
    stringBuffer << "\nproperty float x\nproperty float y\nproperty float z\n";
    stringBuffer << "property uchar red\nproperty uchar green\nproperty uchar blue\n";
    stringBuffer << "end_header\n";
    plystream << stringBuffer.str();
    for(int i = 0; i < this->nodes->numElements; ++i){
      stringBuffer = std::ostringstream("");
      stringBuffer << this->nodes->host[i].center.x;
      stringBuffer << " ";
      stringBuffer << this->nodes->host[i].center.y;
      stringBuffer << " ";
      stringBuffer << this->nodes->host[i].center.z;
      stringBuffer << " ";
      stringBuffer << (int) this->nodes->host[i].color.x;
      stringBuffer << " ";
      stringBuffer << (int) this->nodes->host[i].color.y;
      stringBuffer << " ";
      stringBuffer << (int) this->nodes->host[i].color.z;
      stringBuffer << "\n";
      plystream << stringBuffer.str();
    }
    std::cout<<newFile + " has been created.\n"<<std::endl;
  }
  else{
    std::cout << "Unable to open: " + newFile<< std::endl;
    exit(1);
  }
  this->nodes->transferMemoryTo(origin);
  if(origin == gpu) this->nodes->clear(cpu);
}
void Octree::writespheresPLY(){
  MemoryState origin;
  if(this->spheres != NULL && this->spheres->state != null && this->spheres->numElements != 0){
    origin = this->spheres->state;
    this->spheres->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print spheres without spheres"<<std::endl;
    exit(-1);
  }
  if(this->pathToFile.length() == 0 && this->name.length() == 0){
    this->name = std::to_string(this->depth);
  }
  else if(this->name.length() == 0) this->name = this->pathToFile.substr(this->pathToFile.find_last_of("/") + 1,this->pathToFile.length() - 4);  std::string newFile = "data/" + this->name + "_spheres_" + std::to_string(this->depth)+ ".ply";
	std::ofstream plystream(newFile);
	if (plystream.is_open()) {
    std::ostringstream stringBuffer = std::ostringstream("");
    stringBuffer << "ply\nformat ascii 1.0\ncomment object: SSRL test\n";
    stringBuffer << "element vertex ";
    stringBuffer << this->spheres->numElements;
    stringBuffer << "\nproperty float x\nproperty float y\nproperty float z\n";
    stringBuffer << "property uchar red\nproperty uchar green\nproperty uchar blue\n";
    stringBuffer << "end_header\n";
    plystream << stringBuffer.str();
    float3* currentPoint;
    bool isSurf = false;
    for(int i = 0; i < this->spheres->numElements; ++i){
      isSurf = false;
      stringBuffer = std::ostringstream("");

      currentPoint = &((this->spheres->host)[i].center);
      isSurf = ((this->spheres->host)[i]).surf;

      int color = (isSurf) ? 255 : 0;
      stringBuffer << currentPoint->x;
      stringBuffer << " ";
      stringBuffer << currentPoint->y;
      stringBuffer << " ";
      stringBuffer << currentPoint->z;
      stringBuffer << " ";
      stringBuffer << color;
      stringBuffer << " ";
      stringBuffer << color;
      stringBuffer << " ";
      stringBuffer << color;
      stringBuffer << "\n";
      plystream << stringBuffer.str();
    }
    std::cout<<newFile + " has been created.\n"<<std::endl;
	}
	else{
    std::cout << "Unable to open: " + newFile<< std::endl;
    exit(1);
  }
  this->spheres->transferMemoryTo(origin);
  if(origin == gpu) this->spheres->clear(cpu);
}
void Octree::writeNormalPLY(){
  MemoryState origin[2];
  if(this->normals != NULL && this->normals->state != null && this->normals->numElements != 0){
    origin[0] = this->normals->state;
    this->normals->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print normals without normals"<<std::endl;
    exit(-1);
  }
  if(this->spheres != NULL && this->spheres->state != null && this->spheres->numElements != 0){
    origin[1] = this->spheres->state;
    this->spheres->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print spheres without spheres"<<std::endl;
    exit(-1);
  }
  if(this->pathToFile.length() == 0 && this->name.length() == 0){
    this->name = std::to_string(this->depth);
  }
  else if(this->name.length() == 0) this->name = this->pathToFile.substr(this->pathToFile.find_last_of("/") + 1,this->pathToFile.length() - 4);  std::string newFile = "data/" + this->name + "_normals_" + std::to_string(this->depth)+ ".ply";
	std::ofstream plystream(newFile);
	if (plystream.is_open()) {
    std::ostringstream stringBuffer = std::ostringstream("");
    stringBuffer << "ply\nformat ascii 1.0\ncomment object: SSRL test\n";
    stringBuffer << "element vertex ";
    stringBuffer << this->spheres->numElements;
    stringBuffer << "\nproperty float x\nproperty float y\nproperty float z\n";
    stringBuffer << "property float nx\nproperty float ny\nproperty float nz\n";
    stringBuffer << "end_header\n";
    plystream << stringBuffer.str();
    float3* currentPoint;
    for(int i = 0; i < this->spheres->numElements; ++i){
      stringBuffer = std::ostringstream("");
      currentPoint = &((this->spheres->host)[i].center);
      stringBuffer << currentPoint->x;
      stringBuffer << " ";
      stringBuffer << currentPoint->y;
      stringBuffer << " ";
      stringBuffer << currentPoint->z;
      stringBuffer << " ";
      stringBuffer << this->normals->host[i].x;
      stringBuffer << " ";
      stringBuffer << this->normals->host[i].y;
      stringBuffer << " ";
      stringBuffer << this->normals->host[i].z;
      stringBuffer << "\n";
      plystream << stringBuffer.str();
    }
    std::cout<<newFile + " has been created.\n"<<std::endl;
	}
	else{
    std::cout << "Unable to open: " + newFile<< std::endl;
    exit(1);
  }
  this->normals->transferMemoryTo(origin[0]);
  if(origin[0] == gpu) this->normals->clear(cpu);
  this->spheres->transferMemoryTo(origin[1]);
  if(origin[1] == gpu) this->spheres->clear(cpu);
}
void Octree::writeDepthPLY(int d){
  MemoryState origin[5];
  if(this->vertices != NULL && this->vertices->numElements != 0 && this->vertices->state != null){
    origin[0] = this->vertices->state;
    origin[1] = this->vertexDepthIndex->state;
    this->vertices->transferMemoryTo(cpu);
    this->vertexDepthIndex->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print vertices without vertices"<<std::endl;
    exit(-1);
  }
  if(this->edges != NULL && this->edges->numElements != 0 && this->edges->state != null){
    origin[2] = this->edges->state;
    this->edges->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print edges without edges"<<std::endl;
    exit(-1);
  }
  if(this->faces != NULL && this->faces->numElements != 0 && this->faces->state != null){
    origin[3] = this->faces->state;
    origin[4] = this->faceDepthIndex->state;
    this->faces->transferMemoryTo(cpu);
    this->faceDepthIndex->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot print faces without faces"<<std::endl;
    exit(-1);
  }
  if(d < 0 || d > this->depth){
    std::cout<<"ERROR DEPTH FOR WRITEDEPTHPLY IS OUT OF BOUNDS"<<std::endl;
    exit(-1);
  }
  if(this->pathToFile.length() == 0 && this->name.length() == 0){
    this->name = std::to_string(this->depth);
  }
  else if(this->name.length() == 0) this->name = this->pathToFile.substr(this->pathToFile.find_last_of("/") + 1,this->pathToFile.length() - 4);  std::string newFile = "data/" + this->name +
  "_finestNodes_" + std::to_string(d) + "_"+ std::to_string(this->depth)+ ".ply";
  std::ofstream plystream(newFile);
  if (plystream.is_open()) {

    int verticesToWrite = (depth != 0) ? this->vertexDepthIndex->host[this->depth - d + 1] : this->vertices->numElements;
    int facesToWrite = (depth != 0) ? this->faceDepthIndex->host[this->depth - d + 1] - this->faceDepthIndex->host[this->depth - d] : 6;
    int faceStartingIndex = this->faceDepthIndex->host[this->depth - d];
    std::ostringstream stringBuffer = std::ostringstream("");
    stringBuffer << "ply\nformat ascii 1.0\ncomment object: SSRL test\n";
    stringBuffer << "element vertex ";
    stringBuffer << verticesToWrite;
    stringBuffer << "\nproperty float x\nproperty float y\nproperty float z\n";
    stringBuffer << "property uchar red\nproperty uchar green\nproperty uchar blue\n";
    stringBuffer << "element face ";
    stringBuffer << facesToWrite;
    stringBuffer << "\nproperty list uchar int vertex_index\n";
    stringBuffer << "end_header\n";
    plystream << stringBuffer.str();
    for(int i = 0; i < verticesToWrite; ++i){
      stringBuffer = std::ostringstream("");
      stringBuffer << this->vertices->host[i].coord.x;
      stringBuffer << " ";
      stringBuffer << this->vertices->host[i].coord.y;
      stringBuffer << " ";
      stringBuffer << this->vertices->host[i].coord.z;
      stringBuffer << " ";
      stringBuffer << 50;
      stringBuffer << " ";
      stringBuffer << 50;
      stringBuffer << " ";
      stringBuffer << 50;
      stringBuffer << "\n";
      plystream << stringBuffer.str();
    }
    int2 squareEdges;
    for(int i = faceStartingIndex; i < facesToWrite + faceStartingIndex; ++i){
      stringBuffer = std::ostringstream("");
      squareEdges = {this->faces->host[i].e1,this->faces->host[i].e4};
      stringBuffer << "4 ";
      stringBuffer << this->edges->host[squareEdges.x].v1;
      stringBuffer << " ";
      stringBuffer << this->edges->host[squareEdges.x].v2;
      stringBuffer << " ";
      stringBuffer << this->edges->host[squareEdges.y].v2;
      stringBuffer << " ";
      stringBuffer << this->edges->host[squareEdges.y].v1;
      stringBuffer << "\n";
      plystream << stringBuffer.str();
    }
    std::cout<<newFile + " has been created.\n"<<std::endl;
  }
  else{
    std::cout << "Unable to open: " + newFile<< std::endl;
    exit(1);
  }
  this->vertices->transferMemoryTo(origin[0]);
  if(origin[0] == gpu) this->vertices->clear(cpu);
  this->vertexDepthIndex->transferMemoryTo(origin[1]);
  if(origin[1] == cpu) this->vertexDepthIndex->clear(gpu);
  this->edges->transferMemoryTo(origin[2]);
  if(origin[2] == gpu) this->edges->clear(cpu);
  this->faces->transferMemoryTo(origin[3]);
  if(origin[3] == gpu) this->faces->clear(cpu);
  this->faceDepthIndex->transferMemoryTo(origin[4]);
  if(origin[4] == cpu) this->faceDepthIndex->clear(gpu);
}

void Octree::checkForGeneralNodeErrors(){
  MemoryState origin;
  if(this->nodes != NULL && this->nodes->state != null && this->nodes->numElements != 0){
    origin = this->nodes->state;
    this->nodes->transferMemoryTo(cpu);
  }
  else{
    std::cout<<"ERROR cannot check nodes for errors without nodes"<<std::endl;
    exit(-1);
  }
  clock_t cudatimer;
  cudatimer = clock();
  float regionOfError = this->width/pow(2,depth + 1);
  bool error = false;
  int numFuckedNodes = 0;
  int orphanNodes = 0;
  int nodesWithOutChildren = 0;
  int nodesThatCantFindChildren = 0;
  int noPoints = 0;
  int numSiblingParents = 0;
  int numChildNeighbors = 0;
  bool parentNeighbor = false;
  bool childNeighbor = false;
  int numParentNeighbors = 0;
  int numVerticesMissing = 0;
  int numEgesMissing = 0;
  int numFacesMissing = 0;
  int numCentersOUTSIDE = 0;
  Node* nodes_host = this->nodes->host;

  for(int i = 0; i < this->nodes->numElements; ++i){
    if(nodes_host[i].depth < 0){
      numFuckedNodes++;
    }
    if(nodes_host[i].parent != -1 && nodes_host[i].depth == nodes_host[nodes_host[i].parent].depth){
      ++numSiblingParents;
    }
    if(nodes_host[i].parent == -1 && nodes_host[i].depth != 0){
      orphanNodes++;
    }
    int checkForChildren = 0;
    for(int c = 0; c < 8 && nodes_host[i].depth < 10; ++c){
      if(nodes_host[i].children[c] == -1){
        checkForChildren++;
      }
      if(nodes_host[i].children[c] == 0 && nodes_host[i].depth != this->depth - 1){
        std::cout<<"NODE THAT IS NOT AT 2nd TO FINEST DEPTH HAS A CHILD WITH INDEX 0 IN FINEST DEPTH"<<std::endl;
      }
    }
    if(nodes_host[i].numPoints == 0){
      noPoints++;
    }
    if(nodes_host[i].depth != 0 && nodes_host[nodes_host[i].parent].children[nodes_host[i].key&((1<<3)-1)] == -1){

      nodesThatCantFindChildren++;
    }
    if(checkForChildren == 8){
      nodesWithOutChildren++;
    }
    if(nodes_host[i].depth == 0){
      // if(nodes_host[i].numFinestChildren < this->numFinestUniqueNodes){
      //   std::cout<<"DEPTH 0 DOES NOT INCLUDE ALL FINEST UNIQUE NODES "<<nodes_host[i].numFinestChildren<<",";
      //   std::cout<<this->numFinestUniqueNodes<<", NUM FULL FINEST NODES SHOULD BE "<<this->nodeDepthIndex[1]<<std::endl;
      //   exit(-1);
      // }
      if(nodes_host[i].numPoints != this->spheres->numElements){
        std::cout<<"DEPTH 0 DOES NOT CONTAIN ALL POINTS "<<nodes_host[i].numPoints<<","<<this->spheres->numElements<<std::endl;
        exit(-1);
      }
    }
    childNeighbor = false;
    parentNeighbor = false;
    for(int n = 0; n < 27; ++n){
      if(nodes_host[i].neighbors[n] != -1){
        if(nodes_host[i].depth < nodes_host[nodes_host[i].neighbors[n]].depth){
          childNeighbor = true;
        }
        else if(nodes_host[i].depth > nodes_host[nodes_host[i].neighbors[n]].depth){
          parentNeighbor = true;
        }
      }
    }
    for(int v = 0; v < 8; ++v){
      if(nodes_host[i].vertices[v] == -1){
        ++numVerticesMissing;
      }
    }
    for(int e = 0; e < 12; ++e){
      if(nodes_host[i].edges[e] == -1){
        ++numEgesMissing;
      }
    }
    for(int f = 0; f < 6; ++f){
      if(nodes_host[i].faces[f] == -1){
        ++numFacesMissing;
      }
    }
    if(parentNeighbor){
      ++numParentNeighbors;
    }
    if(childNeighbor){
      ++numChildNeighbors;
    }
    if((nodes_host[i].center.x < this->min.x ||
    nodes_host[i].center.y < this->min.y ||
    nodes_host[i].center.z < this->min.z ||
    nodes_host[i].center.x > this->max.x ||
    nodes_host[i].center.y > this->max.y ||
    nodes_host[i].center.z > this->max.z )){
      ++numCentersOUTSIDE;
    }
  }
  if(numCentersOUTSIDE > 0){
    printf("ERROR %d centers outside of bounding box\n",numCentersOUTSIDE);
    error = true;
  }
  if(numSiblingParents > 0){
    std::cout<<"ERROR "<<numSiblingParents<<" NODES THINK THEIR PARENT IS IN THE SAME DEPTH AS THEMSELVES"<<std::endl;
    error = true;
  }
  if(numChildNeighbors > 0){
    std::cout<<"ERROR "<<numChildNeighbors<<" NODES WITH SIBLINGS AT HIGHER DEPTH"<<std::endl;
    error = true;
  }
  if(numParentNeighbors > 0){
    std::cout<<"ERROR "<<numParentNeighbors<<" NODES WITH SIBLINGS AT LOWER DEPTH"<<std::endl;
    error = true;
  }
  if(numFuckedNodes > 0){
    std::cout<<numFuckedNodes<<" ERROR IN NODE CONCATENATION OR GENERATION"<<std::endl;
    error = true;
  }
  if(orphanNodes > 0){
    std::cout<<orphanNodes<<" ERROR THERE ARE ORPHAN NODES"<<std::endl;
    error = true;
  }
  if(nodesThatCantFindChildren > 0){
    std::cout<<"ERROR "<<nodesThatCantFindChildren<<" PARENTS WITHOUT CHILDREN"<<std::endl;
    error = true;
  }
  if(numVerticesMissing > 0){
    std::cout<<"ERROR "<<numVerticesMissing<<" VERTICES MISSING"<<std::endl;
    error = true;
  }
  if(numEgesMissing > 0){
    std::cout<<"ERROR "<<numEgesMissing<<" EDGES MISSING"<<std::endl;
    error = true;
  }
  if(numFacesMissing > 0){
    std::cout<<"ERROR "<<numFacesMissing<<" FACES MISSING"<<std::endl;
    error = true;
  }
  if(error) exit(-1);
  else std::cout<<"NO ERRORS DETECTED IN OCTREE"<<std::endl;
  std::cout<<"NODES WITHOUT POINTS = "<<noPoints<<std::endl;
  std::cout<<"NODES WITH POINTS = "<<this->nodes->numElements - noPoints<<std::endl<<std::endl;

  printf("octree checkForErrors took %f seconds.\n\n", ((float) clock() - cudatimer)/CLOCKS_PER_SEC);
  this->nodes->transferMemoryTo(origin);
  if(origin == gpu) this->nodes->clear(cpu);
}
