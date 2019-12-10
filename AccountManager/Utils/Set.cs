using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Utils
{
    public static class Set
    {
        public static void IfNew(object source, object target)
        {
            if (source.GetType() != target.GetType())
            {
                MainWindow.Instance.Log.AddError(AccountApi.Origin.Other, "Utils.Set.IfNew was used with different types.");
            }
            if (!source.Equals(target)) target = source;
        }
    }
}
