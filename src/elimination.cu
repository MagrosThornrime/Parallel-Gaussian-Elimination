#include <iomanip>
#include <fstream>

#include "../include/elimination.cuh"

__global__ void findMultipliers(const double* matrix, const int* indices, double* multipliers, int matrixRowSize,
                               int indicesSize, int multipliersRowSize) {
    const int currentIndex = blockIdx.x * blockDim.x + threadIdx.x;
    if(currentIndex >= indicesSize) {
        return;
    }
    const int i = indices[currentIndex * 2];
    const int k = indices[currentIndex * 2 + 1];
    multipliers[k * multipliersRowSize + i] = matrix[k * matrixRowSize + i] / matrix[i * matrixRowSize + i];
}

__global__ void multiplyAndSubtractRows(double* matrix, const int* indices, const double* multipliers, int matrixRowSize,
                                        int indicesSize, int multipliersRowSize) {
    const int currentIndex = blockIdx.x * blockDim.x + threadIdx.x;
    if(currentIndex >= indicesSize) {
        return;
    }
    const int i = indices[currentIndex * 3];
    const int j = indices[currentIndex * 3 + 1];
    const int k = indices[currentIndex * 3 + 2];
    matrix[k * matrixRowSize + j] -= matrix[i * matrixRowSize + j] * multipliers[k *multipliersRowSize + i];
}

__global__ void performTransactions(double* matrix, double* multipliers, double* subtractors, int matrixRowSize,
                                    int multipliersRowSize, const Transaction* transactions, int transactionsSize)
{
    const int currentIndex = blockIdx.x * blockDim.x + threadIdx.x;
    if(currentIndex >= transactionsSize) {
        return;
    }
    transactions[currentIndex].calculate(matrix, multipliers, subtractors, matrixRowSize, multipliersRowSize);

}

void calculateGaussianElimination(std::vector<double>& matrix, int rows, int columns) {
    double* cudaMatrix = nullptr;
    cudaMalloc((void**)&cudaMatrix, rows * columns * sizeof(double));
    cudaMemcpy(cudaMatrix, matrix.data(), rows * columns * sizeof(double), cudaMemcpyHostToDevice);

    std::vector multipliers(rows * rows, 0.0);
    double* cudaMultipliers = nullptr;
    cudaMalloc((void**)&cudaMultipliers, rows * rows * sizeof(double));

    for(int i=0; i<rows-1; i++) {
        std::vector<int> indicesMultiplier;
        std::vector<int> indicesSubtract;
        for(int k=i+1; k<rows; k++) {
            indicesMultiplier.push_back(i);
            indicesMultiplier.push_back(k);
            for(int j=i; j<columns; j++) {
                indicesSubtract.push_back(i);
                indicesSubtract.push_back(j);
                indicesSubtract.push_back(k);
            }
        }
        cudaMemcpy(cudaMultipliers, multipliers.data(), rows * rows * sizeof(double), cudaMemcpyHostToDevice);

        int* cudaIndicesMultiplier = nullptr;
        cudaMalloc((void**)&cudaIndicesMultiplier, indicesMultiplier.size() * sizeof(int));
        cudaMemcpy(cudaIndicesMultiplier, indicesMultiplier.data(), indicesMultiplier.size() * sizeof(int), cudaMemcpyHostToDevice);

        int blocks = indicesMultiplier.size() / 1024 + 1;
        findMultipliers<<<blocks, 1024>>>(cudaMatrix, cudaIndicesMultiplier, cudaMultipliers,
                                        columns, indicesMultiplier.size() / 2, rows);

        int* cudaIndicesSubtract = nullptr;
        cudaMalloc((void**)&cudaIndicesSubtract, indicesSubtract.size() * sizeof(int));
        cudaMemcpy(cudaIndicesSubtract, indicesSubtract.data(), indicesSubtract.size() * sizeof(int), cudaMemcpyHostToDevice);

        blocks = indicesSubtract.size() / 1024 + 1;
        multiplyAndSubtractRows<<<blocks, 1024>>>(cudaMatrix, cudaIndicesSubtract, cudaMultipliers,  columns,
                        indicesSubtract.size() / 3, rows);

        cudaFree(cudaIndicesMultiplier);
        cudaFree(cudaIndicesSubtract);
    }

    cudaMemcpy(matrix.data(), cudaMatrix, rows * columns * sizeof(double), cudaMemcpyDeviceToHost);
    cudaFree(cudaMultipliers);
    cudaFree(cudaMatrix);
}

void calculateFoataElimination(std::vector<double> &matrix, int rows, int columns, const std::vector<std::vector<Transaction> > &foata) {
    double* cudaMatrix = nullptr;
    cudaMalloc((void**)&cudaMatrix, rows * columns * sizeof(double));
    cudaMemcpy(cudaMatrix, matrix.data(), rows * columns * sizeof(double), cudaMemcpyHostToDevice);

    std::vector multipliers(rows * rows, 0.0);
    double* cudaMultipliers = nullptr;
    cudaMalloc((void**)&cudaMultipliers, rows * rows * sizeof(double));

    std::vector subtractors(rows * rows * columns, 0.0);
    double* cudaSubtractors = nullptr;
    cudaMalloc((void**)&cudaSubtractors, rows * rows * columns * sizeof(double));

    Transaction* cudaLevel = nullptr;
    for(const auto& level : foata) {
        cudaMalloc((void**)&cudaLevel, level.size() * sizeof(Transaction));
        cudaMemcpy(cudaLevel,  level.data(), level.size() * sizeof(Transaction), cudaMemcpyHostToDevice);
        int blocks = level.size() / 1024 + 1;
        performTransactions<<<blocks, 1024>>>(cudaMatrix, cudaMultipliers, cudaSubtractors,
                                    columns, rows, cudaLevel, level.size());
        cudaFree(cudaLevel);
    }
    cudaMemcpy(matrix.data(), cudaMatrix, rows * columns * sizeof(double), cudaMemcpyDeviceToHost);
    cudaFree(cudaMultipliers);
    cudaFree(cudaSubtractors);
    cudaFree(cudaMatrix);
}


void transformIntoSingular(std::vector<double>& matrix, int rows, int columns) {
    for(int i=rows-1; i>=0; i--) {
        matrix[i * columns + columns - 1] /= matrix[i * columns + i];
        matrix[i * columns + i] = 1.0;
        for(int j=i-1; j>=0; j--) {
            matrix[j * columns + columns - 1] -= matrix[j * columns + i] * matrix[i * columns + columns - 1];
            matrix[j * columns + i] = 0.0;
        }
    }
}

void saveMatrix(const std::vector<double>& matrix, int rows, int columns, const std::string& path) {
    std::ofstream file(path);
    file << rows << std::endl;
    for(int i=0; i<rows; i++) {
        for(int j=0; j<columns-1; j++) {
            file << std::setprecision(16) << std::fixed << matrix[i * columns + j] << " ";
        }
        file << std::endl;
    }
    for(int i=0; i<rows; i++) {
        file << std::setprecision(16) << std::fixed << matrix[i*columns + columns - 1] << " ";
    }
    file << std::endl;
    file.close();
}

int readMatrix(std::vector<double>& matrix, const std::string& path) {
    std::ifstream file(path);
    int rows;
    file >> rows;
    std::vector<double> coefficients(rows * rows);
    for(int i=0; i<rows*rows; i++) {
        file >> coefficients[i];
    }
    std::vector<double> RHS(rows);
    for(int i=0; i<rows; i++) {
        file >> RHS[i];
    }
    file.close();
    for(int i=0; i<rows; i++) {
        for(int j=0; j<rows; j++) {
            matrix.push_back(coefficients[i * rows + j]);
        }
        matrix.push_back(RHS[i]);
    }
    return rows;
}

void generateTransactions(std::vector<Transaction>& transactions, int matrixSize) {
    for(int i=0; i<matrixSize-1; i++) {
        for(int k=i+1; k<matrixSize; k++) {
            auto multiplier = Transaction(TransactionType::multiplier, {i, k});
            transactions.push_back(multiplier);
            for(int j=i; j<matrixSize+1; j++) {
                auto multiply = Transaction(TransactionType::multiply, {i, j, k});
                transactions.push_back(multiply);
                auto subtract = Transaction(TransactionType::subtract, {i, j, k});
                transactions.push_back(subtract);
            }
        }
    }
}