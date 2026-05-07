using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{
    public class AccountStatus<T>
    {
        public T Account { get; set; } = default(T);

        public bool Exists => Account != null;

        public string Color { get; private set; }
        public string Icon { get; private set; }

        public void FlagOK()
        {
            Color = "DarkGreen";
            Icon = "CheckboxMarkedCircleOutline";
        }

        public void FlagWarning()
        {
            Color = "Chocolate";
            Icon = "CircleEditOutline";
        }

        public void FlagError()
        {
            Color = "DarkRed";
            Icon = "AlertCircleOutline";
        }

        public void SetFlag()
        {
            if (Account == null)
            {
                FlagError();
            }
            else
            {
                FlagOK();
            }
        }
    }
}
