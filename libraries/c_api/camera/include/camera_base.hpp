#pragma once

#include <functional>
#include <atomic>
#include <memory>
#include <string>
#include <vector>

#include <interfaces/api.hpp>

namespace bnb
{
    struct camera_device_description
    {
        std::string localized_name;
    };

    class camera_base
    {
    public:
        using push_frame_cb_t = std::function<void(std::shared_ptr<image_wrapper>)>;

        /*
         * Main thread
         */
        explicit camera_base(push_frame_cb_t cb)
            : m_push_frame_cb(std::move(cb))
            , m_is_abort_requested(false)
            , m_device_index(0)
        {
        }

        virtual void set_device_by_index(uint32_t index) = 0;
        virtual void set_device_by_id(const std::string& device_id) = 0;
        virtual void start() = 0;

        const std::vector<camera_device_description> get_connected_devices() const
        {
            return m_connected_devices;
        }

        size_t get_current_device_index() const
        {
            return m_device_index;
        }

        virtual ~camera_base() = default;

    protected:
        /*
         * Any Thread
         */
        virtual void abort()
        {
            m_is_abort_requested = true;
        }

    protected:
        push_frame_cb_t m_push_frame_cb;
        std::atomic_bool m_is_abort_requested;
        std::vector<camera_device_description> m_connected_devices;
        size_t m_device_index;
    };

    using camera_uptr = std::unique_ptr<camera_base>;
    using camera_sptr = std::shared_ptr<camera_base>;

    camera_sptr create_camera_device(camera_base::push_frame_cb_t cb, size_t index);

} // namespace bnb