using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Exporters.Passwords
{
    abstract public class AbstractPassword
    {
        abstract public JObject ToJson();
    }
}
