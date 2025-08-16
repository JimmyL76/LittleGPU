#include <iostream>
#include <cstdint>
#include <string>
#include <map>
#include <vector>
#include <stdexcept>
#include <sstream>
#include <regex>
#include <fstream>
#include <iomanip>

// global enum for instr types
typedef enum {
    R, I_AR, I_LD, S, B, J, I_JALR, U_LUI, U_AUIPC, SX_S, SX_I, HALT
} eType;

class littleGPUassembler {
private:
    struct instrInfo { // holds instr info given from mnemonic
        eType type;
        uint32_t opcode;
        uint32_t funct3;
        uint32_t funct7;
        bool scalar;

        instrInfo(eType t = R, uint32_t f3 = 0, uint32_t f7 = 0, bool s = false) : funct3(f3), funct7(f7), type(t), scalar(s) {
            switch(t) { // derive opcode from type (with some subtypes)
                case R: opcode = 0b0110011;
                case I_AR: opcode = 0b0010011;
                case I_LD: opcode = 0b0000011;
                case S: opcode = 0b0100011;
                case B: opcode = 0b1100011;
                case J: opcode = 0b1101111;
                case I_JALR: opcode = 0b1100111;
                case U_LUI: opcode = 0b0110111;
                case U_AUIPC: opcode = 0b0010111;
                case SX_S: opcode = 0b1111110;
                case SX_I: opcode = 0b1111101;
                case HALT: opcode = 0b0000000;
            }
        }
    };

    // create maps to index into for actual instruction encoding
    std::map<std::string, instrInfo> instrs;
    std::map<std::string, int32_t> v_regs;
    std::map<std::string, int32_t> s_regs;
    std::map<std::string, uint32_t> labels;
    uint32_t pc; // used for pc+offset relative addressing 

    void initInstrs() {
        instrs.emplace("add", instrInfo(R, 0)); // default values don't need to be specified
        instrs.emplace("sub", instrInfo(R, 0, 32));
        instrs.emplace("xor", instrInfo(R, 4));
        instrs.emplace("or", instrInfo(R, 6));
        instrs.emplace("and", instrInfo(R, 7));
        instrs.emplace("sll", instrInfo(R, 1));
        instrs.emplace("srl", instrInfo(R, 5));
        instrs.emplace("sra", instrInfo(R, 5, 32));
        instrs.emplace("slt", instrInfo(R, 2));
        instrs.emplace("sltu", instrInfo(R, 3));

        instrs.emplace("addi", instrInfo(I_AR, 0));
        instrs.emplace("xori", instrInfo(I_AR, 4));
        instrs.emplace("ori", instrInfo(I_AR, 6));
        instrs.emplace("andi", instrInfo(I_AR, 7));
        instrs.emplace("slli", instrInfo(I_AR, 1));
        instrs.emplace("srli", instrInfo(I_AR, 5));
        instrs.emplace("srai", instrInfo(I_AR, 5, 32));
        instrs.emplace("slti", instrInfo(I_AR, 2));
        instrs.emplace("sltiu", instrInfo(I_AR, 3));

        instrs.emplace("lw", instrInfo(I_LD, 2));
        instrs.emplace("lh", instrInfo(I_LD, 1));
        instrs.emplace("lb", instrInfo(I_LD, 0));
        instrs.emplace("lhu", instrInfo(I_LD, 5));
        instrs.emplace("lbu", instrInfo(I_LD, 4));

        instrs.emplace("sw", instrInfo(S, 2));
        instrs.emplace("sh", instrInfo(S, 1));  
        instrs.emplace("sb", instrInfo(S, 0));

        instrs.emplace("beq", instrInfo(B, 0));
        instrs.emplace("bne", instrInfo(B, 1));
        instrs.emplace("blt", instrInfo(B, 4));
        instrs.emplace("bge", instrInfo(B, 5));
        instrs.emplace("bltu", instrInfo(B, 6));
        instrs.emplace("bgeu", instrInfo(B, 7));

        instrs.emplace("jal", instrInfo(J));
        instrs.emplace("jalr", instrInfo(I_JALR, 0));

        instrs.emplace("lui", instrInfo(U_LUI));
        instrs.emplace("auipc", instrInfo(U_AUIPC));

        instrs.emplace("sx.slt", instrInfo(SX_S, 0, 0, true));
        instrs.emplace("sx.slti", instrInfo(SX_I, 0, 0, true)); 

        instrs.emplace("halt", instrInfo(HALT));
    }

    // creates reg maps
    // ex: translating "x5" into 5 for encoding
    void initRegs() {
        for (int i = 0; i < 32; i++) {
            v_regs["x" + std::to_string(i)] = i; 
        }
        for (int i = 0; i < 32; i++) {
            s_regs["s" + std::to_string(i)] = i;
        }
    }

    // search reg maps for int encoding value
    int parseRegs(const std::string& reg) {
        if (v_regs.find(reg) != v_regs.end()) {
            return v_regs[reg];
        } 
        if (s_regs.find(reg) != s_regs.end()) {
            return s_regs[reg];
        } 
        throw std::runtime_error("Invalid register: " + reg);
    }

    // handle hex, binary, decimal immediates
    int32_t parseImm(const std::string& imm) {
        try {
            if (imm.substr(0,2) == "0x" || imm.substr(0,3) == "-0x") {
                return std::stoi(imm, nullptr, 16);
            } 
            if (imm.substr(0,2) == "0b") {
                return std::stoi(imm.substr(2), nullptr, 2);
            } 
            if (imm.substr(0,3) == "-0b") {
                return -std::stoi(imm.substr(3), nullptr, 2);
            }
            return std::stoi(imm);
        } catch (const std::exception&) {
            throw std::runtime_error("Invalid immediate value: " + imm);
        }
    }

    // remove excess spaces and tabs before and after
    std::string trim(const std::string& str) {
        size_t first = str.find_first_not_of(" \t");
        if (first == std::string::npos) return "";
        size_t last = str.find_last_not_of(" \t");
        return str.substr(first, (last - first + 1));
    }

    std::vector<std::string> split(const std::string& str, char delimiter) {
        std::vector<std::string> tokens;
        std::istringstream s(str);
        std::string token;
        while (std::getline(s, token, delimiter)) {
            tokens.push_back(trim(token));
        }
        return tokens;
    }

    std::pair<std::string, std::vector<std::string>> parseLine(const std::string& line) {
        // remove comments
        std::string clean_line = line;
        size_t comment_pos = clean_line.find('#');
        if (comment_pos != std::string::npos) {
            clean_line = clean_line.substr(0, comment_pos);
        }
        clean_line = trim(clean_line);

        // if empty line, skip
        if (clean_line.empty()) return {"", {}};

        // handle labels
        size_t colon_pos = clean_line.find(':');
        if (colon_pos != std::string::npos) {
            std::string label = clean_line.substr(0, colon_pos);
            clean_line = trim(clean_line.substr(colon_pos + 1));
            labels[label] = pc; // store label with current pc addr
            if (clean_line.empty()) return {"", {}};
        }

        // handle directives
        if (clean_line[0] == '.') return {"", {}};

        // parse instruction and operands
        std::istringstream s(clean_line);
        std::string mnemonic;
        s >> mnemonic;
        std::vector<std::string> operands;
        std::string rest;
        std::getline(s, rest);
        
        if (mnemonic == "halt") {
            return {mnemonic, operands}; // no operands for halt
        }

        if (rest.empty()) throw std::runtime_error("No operands provided for instruction: " + mnemonic);

        rest = trim(rest); // trim spaces between mnemonic/operands and between operands
        operands = split(rest, ','); // split operands by comma

        return {mnemonic, operands}; // ex: mnemonic = "add", operands = {"x1", "x2", "x3"}
    }

    uint32_t encodeInstr(uint32_t opcode, eType type, uint32_t rd, uint32_t rs1, uint32_t rs2, int32_t imm, uint32_t funct3, uint32_t funct7, bool scalar) {
        // set scalar bit if needed
        if (scalar) opcode |= (1 << 6); 

        if (type == R) {
            return (funct7 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode;
        } else if (type == I_AR || type == I_LD || type == I_JALR) {
            uint32_t imm_11_0 = (imm & 0xfff); 
            return (imm_11_0 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | opcode;
        } else if (type == S) {
            uint32_t imm_11_5 = (imm >> 5) & 0x7f;
            uint32_t imm_4_0 = imm & 0x1f;
            return ((imm_11_5 << 25) | (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (imm_4_0 << 7)) | opcode;
        } else if (type == B) {
            uint32_t imm_12 = (imm >> 12) & 0x1;
            uint32_t imm_11 = (imm >> 11) & 0x1;
            uint32_t imm_10_5 = (imm >> 5) & 0x3f;
            uint32_t imm_4_1 = (imm >> 1) & 0xf;
            return ((imm & 0x1E) << 25) | ((rs2 & 0x1f) << 20) | ((rs1 & 0x1f) << 15) | (funct3 << 12) | ((imm >> 5) & 0x7f) | opcode;
        } else if (type == J) {
            return ((imm & 0xfff00000) >> 12) | (rd << 7) | opcode;
        } else if (type == U_LUI || type == U_AUIPC) {
            return imm & 0xfffff000 | rd << 7 | opcode;
        } else if (type == SX_S || type == SX_I) {
            if (type == SX_S) {
                return (rs2 << 20) | (rs1 << 15) | (rd << 7) | opcode;
            } else if (type == SX_I) {
                uint32_t imm_11_0 = (imm & 0xfff); 
                return (imm_11_0 < 20) | (rs1 << 15) | (rd << 7) | opcode;
            }
        } else if (type == HALT) {
            return 0; // representing halt as all 0's
        }
    }

    uint32_t assembleInstr(const std::string& mnemonic, const std::vector<std::string>& operands) {

        // handle scalar instructions
        bool scalar = false;
        std::string real_mnemonic = mnemonic;
        if (mnemonic.substr(0, 2) == "s.") {
            scalar = true;
            real_mnemonic = mnemonic.substr(2);
        } 
        if (instrs.find(real_mnemonic) == instrs.end()) throw std::runtime_error("Unknown instruction: " + real_mnemonic);
        const instrInfo& info = instrs[real_mnemonic];
        if (!scalar) scalar = info.scalar; // if not vector turned into scalar, assign scalar value

        uint32_t rd, rs1, rs2;
        int32_t imm;

        // check for operand errors and handle parsing differently per instr
        if (info.type == R || info.type == I_AR || info.type == SX_S || info.type == SX_I) { // SX. instrs are treated the same, will just always use s1 as rd
            if (operands.size() != 3) throw std::runtime_error("Requires 3 operands");
            rd = parseRegs(operands[0]);
            rs1 = parseRegs(operands[1]);
            if (info.type == R) rs2 = parseRegs(operands[2]);
            else imm = parseImm(operands[2]);
        } else if (info.type == I_JALR || info.type == I_LD || info.type == S) {
            if (operands.size() != 2) throw std::runtime_error("Requires 2 operands with base + offset");
            rd = parseRegs(operands[0]);
            std::regex regex(R"((-?\d+|0x[0-9a-fA-F]+)\((\w+)\))");
            std::smatch match;
            if (std::regex_match(operands[1], match, regex)) {
                rs1 = parseRegs(match[0].str());
                imm = parseImm(match[1].str());
            } else {
                throw std::runtime_error("Does not match offset(base) syntax");
            }
        } else if (info.type == B) {
            if (operands.size() != 3) throw std::runtime_error("Requires 3 operands");
            rs1 = parseRegs(operands[0]);
            rs2 = parseRegs(operands[1]);
            if (labels.find(operands[2]) == labels.end()) {
                // this check only works if: labels are not allowed to be named anything that could be mistaken for an imm (for which the programmer writes an intended imm that happens to correspond to a label of the same characters)
                imm = parseImm(operands[2]); 
            } else {
                imm = labels[operands[2]] - pc; // actual int types don't need parseImm
            }
        } else if (info.type == J || info.type == U_LUI || info.type == U_AUIPC) {
            if (operands.size() != 2) throw std::runtime_error("Requires 2 operands");
            rd = parseRegs(operands[0]);
            if (labels.find(operands[1]) == labels.end()) imm = parseImm(operands[1]); 
            else imm = labels[operands[1]] - pc; 
        } // no additional logic here needed for HALT

        return encodeInstr(info.opcode, info.type, rd, rs1, rs2, imm, info.funct3, info.funct7, scalar);
    }
public:
    littleGPUassembler() : pc(0) {
        initInstrs();
        initRegs();
    }

    bool assemble(const std::string& input_file, const std::string& output_file) {
        // check input file
        std::ifstream in(input_file);
        if (!in) {
            std::cerr << "Cannot open input file: " << input_file << std::endl;
            return false;
        }

        // grab lines
        std::vector<std::string> lines;
        std::string line;
        while (std::getline(in, line)) lines.push_back(line);
        in.close();

        // first pass: grab labels
        for (const auto& line : lines) {
            auto [mnemonic, operands] = parseLine(line);
            if (!mnemonic.empty()) pc += 4; // do this instead of line.empty, line might get lines with just comments or spaces
        }

        // second pass: generate machine code
        std::vector<uint32_t> machine_code;
        pc = 0;
        for (size_t line_num = 0; line_num < lines.size(); line_num++) {
            try {
                auto [mnemonic, operands] = parseLine(lines[line_num]);
                if (!mnemonic.empty()) {
                    machine_code.push_back(assembleInstr(mnemonic, operands));
                    pc += 4;
                }
            } catch (const std::exception& e) {
                std::cerr << "Error on line " << (line_num + 1) << ": " << lines[line_num] << std::endl; // line num should start at 1
                std::cerr << e.what() << std::endl;
                return false;
            }
        }

        // write to output file
        std::ofstream out(output_file);
        if (!out) {
            std::cerr << "Cannot open output file: " << output_file << std::endl;
            return false;
        }
        for (uint32_t code : machine_code) {
            out << std::hex << std::uppercase << std::setfill('0') << std::setw(8) << code << std::endl;
        }
        out.close();

        std::cout << "Assembled successfully " << machine_code.size() << "instructions" << std::endl;
        return true;

    }

};

int main(int argc, char* argv[]) {
    if (argc != 3) std::cerr << "Usage: " << argv[0] << " <input.asm> <output.mem>" << std::endl; // argv[0] --> guaranteed to have program name
    return 1;

    littleGPUassembler assembler;
    bool success = assembler.assemble(argv[1], argv[2]);
    return success ? 0 : 1;
}