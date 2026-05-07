using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.State.Linked
{
    public class GroupStatus<T>
    {
        public T Group { get; set; } = default(T);

        public bool Linked => Group != null;

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
            if (Group == null)
            {
                FlagError();
            } else
            {
                FlagOK();
            }
        }
    }
}
