package bullet_dodge


import "base:intrinsics"
import "base:runtime"
import "core:mem"


AllocatorData :: struct {
    prev_offsets:     []u16,
    alloc_sizes:      []u16,
    data:             []u8,
    n_current_allocs: u16,
    offset:           u16
}

custom_alloc :: proc(allocator_data: ^AllocatorData, size: u16, alignment: u8) -> ([]byte, mem.Allocator_Error) {
    initial_address := allocator_data.offset + allocator_data.offset % u16(alignment)

    if len(allocator_data.data) - int(initial_address) >= int(size) {
        data_ptr := mem.byte_slice(&allocator_data.data[initial_address], size)

        allocator_data.prev_offsets[allocator_data.n_current_allocs] = allocator_data.offset
        allocator_data.alloc_sizes[allocator_data.n_current_allocs] = allocator_data.offset % u16(alignment) + size

        allocator_data.offset           += allocator_data.offset % u16(alignment) + size
        allocator_data.n_current_allocs += 1

        return data_ptr, .None
    }

    return nil, .Out_Of_Memory
}

custom_alloc_zeroed :: proc(allocator_data: ^AllocatorData, size: u16, alignment: u8) -> ([]byte, mem.Allocator_Error) {
    data_ptr, err := custom_alloc(allocator_data, size, alignment)
    if err != .None { return nil, err }

    for i in 0..<size {
        data_ptr[i] = 0
    }

    return data_ptr, .None
}

custom_free :: proc(allocator_data: ^AllocatorData, old_memory: rawptr) -> ([]byte, mem.Allocator_Error) {
    last_alloc_idx := allocator_data.n_current_allocs - 1
    if 
        intrinsics.ptr_sub((^u8)(old_memory), &allocator_data.data[0]) > int(allocator_data.prev_offsets[last_alloc_idx]) ||
        intrinsics.ptr_sub((^u8)(old_memory), &allocator_data.data[0]) < 0 
    {
        return nil, .Invalid_Pointer
    }

    allocator_data.offset = allocator_data.prev_offsets[last_alloc_idx]
    allocator_data.n_current_allocs -= 1

    return nil, .None
}

custom_free_all :: proc(allocator_data: ^AllocatorData) -> ([]byte, mem.Allocator_Error) {
    allocator_data.offset = 0
    allocator_data.n_current_allocs = 0

    return nil, .None
}

custom_resize :: proc(
    allocator_data: ^AllocatorData,
    old_memory:     rawptr,
    new_size:       int,
    alignment:      int,
    old_size:       int
) -> ([]byte, mem.Allocator_Error) {
    if new_size == 0 {
        custom_free(allocator_data, old_memory)
    }

    last_alloc_idx := allocator_data.n_current_allocs - 1
    if 
        intrinsics.ptr_sub((^u8)(old_memory), &allocator_data.data[0]) > int(allocator_data.prev_offsets[last_alloc_idx]) ||
        intrinsics.ptr_sub((^u8)(old_memory), &allocator_data.data[0]) < 0 
    {
        return nil, .Invalid_Pointer
    }

    new_memory, err_new_memory := custom_alloc(allocator_data, u16(new_size), u8(alignment))
    if err_new_memory != .None { return nil, err_new_memory }

    copy_size := new_size < old_size ? new_size : old_size
    copy_slice(new_memory, mem.byte_slice(old_memory, copy_size))

    total_size := 0
    i: u16
    for i = 0; total_size <= copy_size; i += 1 {
        total_size += int(allocator_data.alloc_sizes[i])
    }

    if total_size > copy_size { i -= 1 }
    allocator_data.n_current_allocs = i

    return new_memory, .None
}

custom_allocator_proc :: proc(
    alloc_data: rawptr,
    mode:           mem.Allocator_Mode,
    size:           int,
    alignment:      int,
    old_memory:     rawptr,
    old_size:       int,
    location:       runtime.Source_Code_Location = #caller_location
) -> ([]byte, mem.Allocator_Error) {
    allocator_data := cast(^AllocatorData)alloc_data

    switch mode {
        case .Alloc:
            return custom_alloc_zeroed(allocator_data, u16(size), u8(alignment))
        case .Alloc_Non_Zeroed:
            return custom_alloc(allocator_data, u16(size), u8(alignment))
        case .Free:
            return custom_free(allocator_data, old_memory)
        case .Free_All:
            return custom_free_all(allocator_data)
        case .Resize:
            return custom_resize(allocator_data, old_memory, size, alignment, old_size)
        case .Resize_Non_Zeroed:
            return nil, .Mode_Not_Implemented
        case .Query_Features:
            set := (^mem.Allocator_Mode_Set)(old_memory)
            if set != nil {
                set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Free_All, .Resize, .Query_Features}
            }
            return nil, nil
        case .Query_Info:
            return nil, .Mode_Not_Implemented
    }

    return nil, nil
}

init_allocator :: proc(allocator_data: ^AllocatorData, size: u16) {
    data, err_data := mem.alloc_bytes(int(size))
    if err_data != .None do panic("Error allocating memory.")

    prev_offsets, err_prev_offsets := mem.make_aligned([]u16, int(size), int(size))
    if err_prev_offsets != mem.Allocator_Error.None do panic("Error allocating memory for previous offsets.")
    alloc_sizes, err_alloc_sizes := mem.make_aligned([]u16, int(size), int(size))
    if err_alloc_sizes != mem.Allocator_Error.None do panic("Error allocating memory for the size of each allocation.")

    allocator_data^ = {
        data         = data,
        prev_offsets = prev_offsets,
        alloc_sizes  = alloc_sizes
    }
}

free_allocator_data :: proc(allocator_data: ^AllocatorData) {
    mem.free_bytes(allocator_data.data)
    delete(allocator_data.prev_offsets)
    delete(allocator_data.alloc_sizes)
}

get_custom_allocator :: proc(allocator_data: ^AllocatorData) -> mem.Allocator {
    return {
        procedure = custom_allocator_proc,
        data      = allocator_data
    }
}