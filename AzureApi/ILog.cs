using System;
using System.Collections.Generic;
using System.Text;

namespace AzureApi
{
    public interface ILog
    {
        void AddMessage(Origin origin, string message);
        void AddError(Origin origin, string message);
    }
}
