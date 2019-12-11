using System;
using System.Threading.Tasks;

namespace AccountManager.Action.Group
{
    public class AddToDirectory : GroupAction
    {
        public override Task Apply(State.Linked.LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public AddToDirectory() : base(
            "Klas toevoegen aan Active Directory",
            "Voeg deze klas toe aan Active Directory.",
            true)
        {

        }

        public static bool Evaluate(State.Linked.LinkedGroup group)
        {
            if (group.Wisa.Linked && !group.Directory.Linked)
            {
                group.Actions.Add(new AddToDirectory());
                return true;
            }
            return false;
        }
    }
}
